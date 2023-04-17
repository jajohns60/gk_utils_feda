#!/usr/intel/pkgs/perl/5.26.1/bin/perl

package GkUtil;

use strict;
use warnings;

use parent qw(Exporter);

our @EXPORT = qw();
our @EXPORT_OK = qw(&run_command);
our %EXPORT_TAGS =
  (
   print => [qw(&info &error &fatal_error &warning &debug &prefix_lines)],
  );
Exporter::export_ok_tags(qw(print));

use Cwd;
use Data::Dumper;
use File::Spec::Functions qw(canonpath catdir splitdir);
use IO::Socket;
use POSIX qw(:sys_wait_h);

# Declare global variable to avoid warning that this is used once
package main { our %GkConfig; };    ## no critic (Modules::ProhibitMultiplePackages)

our $prefix_char = '%';
our $prefix = "GkUtil";
our $pretend = 0;
our $quiet = $ENV{QUIET_MODE} || 0;
our $debug = 0;
our $record_warnings = 0;
our $record_errors = 0;
our (@warning_messages, @error_messages);
our ($info_handle, $error_handle, $fatal_error_handle, $warning_handle, $debug_handle);
&set_default_print_handles(1);

##---------------------------------------------------------------------------------------------------
## run_command()
##   execute given command and return status
##   output is returned through second argument array ref
##   third parameter is mode hash containing optional fields that control timeout, quiet mode,
##     output redirection and logging:
##     timeout     => non-zero number: kill command after given number of seconds
##     force_quiet => true: do not print informational statements, false: follow quiet mode setting
##     no_redirect => true: do not redirect STDERR to STDOUT, false: redirect STDERR to STDOUT
##     log_file    => filename: send STDOUT/STDERR to given file
##---------------------------------------------------------------------------------------------------
sub run_command {
  my ($command, $results_ref, $mode_hash) = @_;
  $mode_hash = {} unless ((ref $mode_hash) eq 'HASH');

  my $fh;
  my $close_fh;
  my $status = 1;
  my $log_file = $$mode_hash{log_file};
  my $timeout = $$mode_hash{timeout};
  my $quiet_mode = &is_quiet() || $$mode_hash{force_quiet};

  # $log_file will eq FileHandle if it was created using a filehandle object
  # Otherwise, it is likely to be a GLOB
  if ($log_file && !&is_pretend()) {
    if (((ref $log_file) eq 'FileHandle') || ((ref $log_file) eq 'GLOB')) {
      # Create an alias for the filehandle
      if (not open $fh, q{>&}, $log_file) {
        &info("Cannot open log file log_file: ${!}");
        undef($fh);
      }
    } else {
      if (open $fh, q{>>}, $log_file) {
        $close_fh = 1;
      } else {
        &info("Cannot open log file ${log_file}: ${!}");
        undef($fh);
      }
    }
    $fh->autoflush() if ($fh);
  }

  if (!$quiet_mode) {
    my $timeout_string = ((defined $timeout)? "${timeout}" : "undef");
    if ($log_file && !(ref $log_file)) {
      &info("Running Command (tout => ${timeout_string}, log => ${log_file}): '${command}'");
    } else {
      &info("Running Command (tout => ${timeout_string}): '${command}'");
    }
    if ($fh) {
      my $old_fh = select();
      select($fh);
      &info("Running Command (tout => ${timeout_string}): '${command}'");
      select($old_fh);
    }
  }

  if (!$pretend) {
    my $full_command;
    if ($$mode_hash{no_redirect}) {
      $full_command = "${command}";
    } else {
      $full_command = "${command} 2>&1";
    }

    if ($status = open my $cmd_pipe, q{-|}, $full_command) {
      my $rin = '';
      vec($rin, fileno($cmd_pipe), 1) = 1;
      my ($nfound, $timeLeft) = select($rin, undef, undef, $timeout);
      my $result;

      if ($nfound) {
        my $offset = 0;
        my $bytes = 0;
        do {
          $offset += $bytes;
          $bytes = sysread($cmd_pipe, $result, 1024, $offset)
        } while ($bytes);

        print {$fh} $result if ($fh);
        @$results_ref = split("\n", $result);
        $status = close $cmd_pipe;
      } else {
        &info("Timed out waiting for data on pipe, killing process") unless ($quiet_mode);
        kill 9, $status;
        $status = 0;
        close $cmd_pipe;
      }
    } else {
      $status = 0;
      &error("Unable to execute command: ${!}");
    }
  }

  close $fh if ($fh && $close_fh);

  return $status;
}                               # sub run_command

##---------------------------------------------------------------------------------------------------
## run_commands()
##   execute given commands from hash ref and return status
##   list of failed commands is returned as second field array ref
##   second parameter is mode hash containing optional fields that control parallel, blocking, and
##     sleep time:
##     parallel   => true: commands are forked in parallel, false: commands are run serially
##     noblock    => true: command status is not checked or waited on, false: commands are waited on
##                   and checked
##     sleep_time => nonzero number: wait given number of seconds between checks on child processes
##---------------------------------------------------------------------------------------------------
sub run_commands {
  my ($command_list, $mode_hash) = @_;
  $mode_hash = {} unless ((ref $mode_hash) eq 'HASH');

  my %pids = ();
  my @failed;
  my $errors = 0;
  my $running = 0;
  my $quiet_mode = &is_quiet() || $$mode_hash{force_quiet};

  if ($$mode_hash{parallel} && !$$mode_hash{noblock}) {
    my @commands = @$command_list;

    my $max_parallel = (scalar @commands);
    if (exists $$mode_hash{max_parallel}) {
      $max_parallel = $$mode_hash{max_parallel};
    }
    $max_parallel ||= (scalar @commands);

    my $kid = 0;
    my $hit_max_errors = 0;
    do {
      if ($running && ((my $kid = waitpid(-1, WNOHANG)) > 0)) {
	--$running;
	my $status = $?;
	my $command = $pids{$kid};
	if ($status == -1) {
	  &error("Failed to execute: ${!}");
          push(@failed, $command);
	  ++$errors;
	} elsif ($status & 127) {
	  &error("Child died with signal" .
                 sprintf('%d, %s coredump', ($status & 127), ($status & 128)? 'with' : 'without')
                );
          push(@failed, $command);
	  ++$errors;
	} elsif ($status) {
	  my $exit_status = $status >> 8;
	  &error("Command Failed (Exit = ${exit_status}): `${command}`");
          push(@failed, $command);
	  ++$errors;
	} else {
	  &info("Command Succeeded: `${command}`") unless ($quiet_mode);
	}
      }

      if ($$mode_hash{max_errors} && $errors >= $$mode_hash{max_errors}) {
        $hit_max_errors = 1;
        next;
      }

      my @bunch = splice(@commands, 0, $max_parallel - $running);

      foreach my $command (@bunch) {
        if (&is_pretend()) {
          &info("MOCK: Forking off command `${command}`") unless ($quiet_mode);
        } else {
          my $pid = fork();
          if ($pid) {
            $pids{$pid} = $command;
            ++$running;
          } elsif (defined $pid) {
            &info("Forking off command `${command}`") unless ($quiet_mode);
            exec($command);
          } else {
            &error("Cannot Fork command `${command}`");
            ++$errors;
          }
        }
      }

      sleep($$mode_hash{sleep_time}) if ($$mode_hash{sleep_time} && $$mode_hash{sleep_time} > 0);
    } while (($running > 0) || (@commands && !$hit_max_errors));

  } else {

    foreach my $command (@$command_list) {
      if ($$mode_hash{parallel}) {
        my $parallel_command = "${command} &";
        if (&is_pretend()) {
          &info("MOCK: Forking off command `${parallel_command}`") unless ($quiet_mode);
        } else {
          &info("Forking off command `${parallel_command}`") unless ($quiet_mode);
          my $status = system($parallel_command);
          if ($status) {
            if ($? == -1) {
              &error("Failed to execute: ${!}");
              ++$errors;
            } elsif ($? & 127) {
              &error("Child died with signal" .
                     sprintf('%d, %s coredump', ($? & 127), ($? & 128)? 'with' : 'without')
                    );
              push(@failed, $command);
              ++$errors;
            } else {
              my $exit_status = $? >> 8;
              &error("Command Failed (Exit = ${exit_status}): `${command}`");
              push(@failed, $command);
              ++$errors;
            }
          } else {
            &info("Command Successfully Forked: `${command}`") unless ($quiet_mode);
          }
        }
      } else {
        if (&is_pretend()) {
          &info("MOCK: Running command `${command}`") unless ($quiet_mode);
        } else {
          &info("Running command `${command}`") unless ($quiet_mode);
          my $status = system($command);
          if ($status) {
            if ($? == -1) {
              &error("Failed to execute: ${!}");
              push(@failed, $command);
              ++$errors;
            } elsif ($? & 127) {
              my $signal = $? & 127;

              &error("Child died with signal" .
                     sprintf('%d, %s coredump', $signal, ($? & 128)? 'with' : 'without')
                    );

              push(@failed, $command);
              ++$errors;

              if ($signal == POSIX::SIGQUIT || $signal == POSIX::SIGINT || $signal == POSIX::SIGKILL) {
                if ($$mode_hash{nodie}) {
                  return ($errors, \@failed);
                } else {
                  &fatal_error("Killed by signal ${signal}");
                }
              }
            } else {
              my $exit_status = $? >> 8;
              &error("Command Failed (Exit = ${exit_status}): `${command}`");
              push(@failed, $command);
              ++$errors;
            }
          } else {
            &info("Command Succeeded: `${command}`") unless ($quiet_mode);
          }
        }
      }

      if ($$mode_hash{max_errors} && $errors >= $$mode_hash{max_errors}) {
        return ($errors, \@failed);
      }
    }
  }

  return ($errors, \@failed);
}				# sub run_commands

##---------------------------------------------------------------------------------------------------
## source_environment_signal_handler()
##   signal handler for ENV setup
##---------------------------------------------------------------------------------------------------
sub source_environment_signal_handler
{
  my ($signame) = @_;
  my $error_msg = "Received Interrupt SIG{${signame}}\n";
  &fatal_error($error_msg);


}    
##---------------------------------------------------------------------------------------------------
## source_environment()
##   apply environment changes from given shell script and return status
##---------------------------------------------------------------------------------------------------
sub source_environment {
  my ($source_command,$env_type,$env_file_path,$alarm_timeout) = @_;

  # Setup Project Specific Environment for tool to work.
  # For HDK and most ENV, we can simply take the source command, and add printenv an capture the output.
  # For backwater CTH env, which wants to create a WINDOW, we need to create a persistent copy of the ENV in a file.
  my ($cmd,$timeout);
  if(defined $env_type && ($env_type eq "cth"))
   {
     $cmd = "/bin/csh -f -c '${source_command} printenv>$env_file_path'";
     print "Using CTH ENV Setup Command : ${source_command}\n";
   }     
  elsif(defined $env_type && ($env_type eq "cth_psetup"))
   {
     $cmd = "/bin/csh -f -c '${source_command} -cmd printenv>$env_file_path'";
     print "Using CTH ENV Setup Command : ${source_command}\n";
   }     
  else
   {
     $cmd = "/bin/csh -f -c '${source_command}; printenv'";
     print "Using HDK ENV Setup Command : ${source_command}\n";
   }   

  # Setup Signal Handler and alarm 
  $timeout = (defined $alarm_timeout ) ? $alarm_timeout : 300;

  local $SIG{INT}  = \&source_environment_signal_handler;
  local $SIG{PIPE} = \&source_environment_signal_handler;
  local $SIG{ALRM} = \&source_environment_signal_handler;
  local $SIG{TERM} = \&source_environment_signal_handler;
  alarm($timeout);
  
  # Source ENV cmd
  print "Sourcing the ENV as $cmd\n"; 
  chomp(my @cmd_results = `${cmd}`);
  my $status = $?;
  if ($status == 0) {
    # For HDK ENV   
    if(!defined $env_type) 
     {
       foreach my $env (@cmd_results) {
         my ($var, $val) = split(/\s*=\s*/, $env, 2);
         if ($var and $val) {
           &debug("\t${var} = ${val}");
           $ENV{$var} = $val;
         }
       }
     }     
    # For CTH ENV
    if(defined $env_type && (($env_type eq "cth") || ($env_type eq "cth_psetup")))
     {
       open my $env_fh, q{<}, $env_file_path;
       while(<$env_fh>)
        {
          # Remove newline, read ENV and set.    
          chomp($_);   
          my ($var, $val) = split(/\s*=\s*/, $_, 2); 
          if ($var and $val) {
           &debug("\t${var} = ${val}");
           $ENV{$var} = $val;
          }      
        }      
       close $env_fh;
     }     
  }
  # Unset alarm and return status
  alarm(0); 
  return $status;
}# sub source_environment

##---------------------------------------------------------------------------------------------------
## process_cmd_subs()
##   Perform standard pattern substitutions on given scalar, scalar ref, or array ref (changes array).
##   Optionally perform more substitutions if patterns are passed in.
##---------------------------------------------------------------------------------------------------
sub process_cmd_subs {
  my ($string_ref, $patterns) = @_;
  my $return_string;

  my $array_ref;
  if (ref $string_ref) {
    if ((ref $string_ref) eq 'ARRAY') {
      $array_ref = $string_ref;
    } elsif ((ref $string_ref) eq 'SCALAR') {
      $array_ref = [$string_ref];
    } else {
      $array_ref = [];
      &error("Type " . (ref $string_ref) . " not supported in &process_cmd_subs");
    }
  } else {
    $return_string = $string_ref;
    $array_ref = [\$return_string];
  }

  return $return_string unless ($patterns && ((ref $patterns) eq 'HASH'));

  foreach my $ref (@$array_ref) {
    my $string;
    if (ref $ref) {
      if ((ref $ref) eq 'SCALAR') {
        $string = $$ref;
      } else {
        &error("Sub type " . (ref $ref) . " not supported in &process_cmd_subs");
        next;
      }
    } else {
      $string = $ref;
    }

    if ($string) {
      foreach my $key (keys %{$patterns}) {
        $string =~ s/<\Q${key}\E>/$patterns->{$key}/g;
#       $string =~ s/\/\Q${key}\E\//$patterns->{$key}/g;
      }

      if (ref $ref) {
        $$ref = $string;
      } else {
        $ref = $string;
      }
    }

    $return_string = $string;
  }

  return $return_string;
}

##---------------------------------------------------------------------------------------------------
## set_pretend()
##   set pretend/no-run/mock mode flag
##---------------------------------------------------------------------------------------------------
sub set_pretend {
  ($pretend) = @_;
}				# sub set_pretend

##---------------------------------------------------------------------------------------------------
## set_pretend()
##   return pretend/no-run/mock mode flag
##---------------------------------------------------------------------------------------------------
sub is_pretend {
  return $pretend;
}				# sub is_pretend

##---------------------------------------------------------------------------------------------------
## set_quiet()
##   set quiet mode flag
##---------------------------------------------------------------------------------------------------
sub set_quiet {
  ($ENV{QUIET_MODE}) = ($quiet) = @_;
}				# sub set_quiet

##---------------------------------------------------------------------------------------------------
## is_quiet()
##   return quiet mode flag
##---------------------------------------------------------------------------------------------------
sub is_quiet {
  return $quiet;
}				# sub is_quiet

##---------------------------------------------------------------------------------------------------
## set_debug()
##   set debug mode flag
##---------------------------------------------------------------------------------------------------
sub set_debug {
  ($debug) = @_;
}				# sub set_debug

##---------------------------------------------------------------------------------------------------
## is_debug()
##   return debug mode flag
##---------------------------------------------------------------------------------------------------
sub is_debug {
  return $debug;
}				# sub is_debug

##---------------------------------------------------------------------------------------------------
## set_prefix()
##   set the prefix for print commands
##---------------------------------------------------------------------------------------------------
sub set_prefix {
  ($prefix) = @_;
}				# sub set_prefix

##---------------------------------------------------------------------------------------------------
## get_prefix()
##   return the prefix for print commands
##---------------------------------------------------------------------------------------------------
sub get_prefix {
  ($prefix) = @_;
}				# sub get_prefix

##---------------------------------------------------------------------------------------------------
## is_prefix()
##   return the prefix for print commands
##---------------------------------------------------------------------------------------------------
sub is_prefix {
  return $prefix;
}

##---------------------------------------------------------------------------------------------------
## set_prefix_char()
##   set the prefix_char for print commands
##---------------------------------------------------------------------------------------------------
sub set_prefix_char {
  ($prefix_char) = @_;
}				# sub set_prefix_char

##---------------------------------------------------------------------------------------------------
## is_prefix_char()
##   return the prefix_char for print commands
##---------------------------------------------------------------------------------------------------
sub is_prefix_char {
  return $prefix_char;
}			

##---------------------------------------------------------------------------------------------------
## set_record_warnings()
##   set record_warnings mode flag
##---------------------------------------------------------------------------------------------------
sub set_record_warnings {
  ($record_warnings) = @_;
}				# sub set_record_warnings

##---------------------------------------------------------------------------------------------------
## is_record_warnings()
##   return record_warnings mode flag
##---------------------------------------------------------------------------------------------------
sub is_record_warnings {
  return $record_warnings;
}				# sub is_record_warnings

##---------------------------------------------------------------------------------------------------
## get_warnings()
##   return the recorded warnings and optionally clear the list
##---------------------------------------------------------------------------------------------------
sub get_warnings {
  my ($clear) = @_;
  if ($clear) {
    my @temp = @warning_messages;
    @warning_messages = ();
    return @temp;
  }
  return @warning_messages;
}				# sub get_warnings

##---------------------------------------------------------------------------------------------------
## set_record_errors()
##   set record_errors mode flag
##---------------------------------------------------------------------------------------------------
sub set_record_errors {
  ($record_errors) = @_;
}				# sub set_record_errors

##---------------------------------------------------------------------------------------------------
## is_record_errors()
##   return record_errors mode flag
##---------------------------------------------------------------------------------------------------
sub is_record_errors {
  return $record_errors;
}				# sub is_record_errors

##---------------------------------------------------------------------------------------------------
## get_errors()
##   return the recorded errors and optionally clear the list
##---------------------------------------------------------------------------------------------------
sub get_errors {
  my ($clear) = @_;
  if ($clear) {
    my @temp = @error_messages;
    @error_messages = ();
    return @temp;
  }
  return @error_messages;
}				# sub get_errors

##---------------------------------------------------------------------------------------------------
## set_info_handle()
##   sets info handler
##---------------------------------------------------------------------------------------------------
sub set_info_handle {
  ($info_handle) = @_;
}                               # sub set_info_handle

##---------------------------------------------------------------------------------------------------
## set_error_handle()
##   sets error handler
##---------------------------------------------------------------------------------------------------
sub set_error_handle {
  ($error_handle) = @_;
}                               # sub set_error_handle

##---------------------------------------------------------------------------------------------------
## set_fatal_error_handle()
##   sets fatal_error handler
##---------------------------------------------------------------------------------------------------
sub set_fatal_error_handle {
  ($fatal_error_handle) = @_;
}                               # sub set_fatal_error_handle

##---------------------------------------------------------------------------------------------------
## set_warning_handle()
##   sets warning handler
##---------------------------------------------------------------------------------------------------
sub set_warning_handle {
  ($warning_handle) = @_;
}                               # sub set_warning_handle

##---------------------------------------------------------------------------------------------------
## set_debug_handle()
##   sets debug handler
##---------------------------------------------------------------------------------------------------
sub set_debug_handle {
  ($debug_handle) = @_;
}                               # sub set_debug_handle

##---------------------------------------------------------------------------------------------------
## set_default_print_handles()
##   print debug statement if debug mode is on
##---------------------------------------------------------------------------------------------------
sub set_default_print_handles {
  my ($undef_only) = @_;
  &set_info_handle(\&default_info) unless ($undef_only && $info_handle);
  &set_error_handle(\&default_error) unless ($undef_only && $error_handle);
  &set_fatal_error_handle(\&default_fatal_error) unless ($undef_only && $fatal_error_handle);
  &set_warning_handle(\&default_warning) unless ($undef_only && $warning_handle);
  &set_debug_handle(\&default_debug) unless ($undef_only && $debug_handle);
}                               # sub set_default_print_handles

##---------------------------------------------------------------------------------------------------
## set_default_prefix_print_handles()
##   print debug statement if debug mode is on
##---------------------------------------------------------------------------------------------------
sub set_default_prefix_print_handles {
  my ($undef_only) = @_;
  &set_info_handle(\&default_prefix_info) unless ($undef_only && $info_handle);
  &set_error_handle(\&default_prefix_error) unless ($undef_only && $error_handle);
  &set_fatal_error_handle(\&default_prefix_fatal_error) unless ($undef_only && $fatal_error_handle);
  &set_warning_handle(\&default_prefix_warning) unless ($undef_only && $warning_handle);
  &set_debug_handle(\&default_prefix_debug) unless ($undef_only && $debug_handle);
}                               # sub set_default_prefix_print_handles

##---------------------------------------------------------------------------------------------------
## info()
##   print info statement
##---------------------------------------------------------------------------------------------------
sub info {
  &$info_handle(@_);
}                               # sub info

##---------------------------------------------------------------------------------------------------
## error()
##   print error statement
##---------------------------------------------------------------------------------------------------
sub error {
  &$error_handle(@_);
  push(@error_messages, @_) if ($record_errors);
}                               # sub error

##---------------------------------------------------------------------------------------------------
## fatal_error()
##   print error statement and exit with failure status (default behavior)
##---------------------------------------------------------------------------------------------------
sub fatal_error {
  &$fatal_error_handle(@_);
  push(@error_messages, @_) if ($record_errors);
}                               # sub fatal_error

##---------------------------------------------------------------------------------------------------
## warning()
##   print warning statement
##---------------------------------------------------------------------------------------------------
sub warning {
  &$warning_handle(@_);
  push(@warning_messages, @_) if ($record_warnings);
}                               # sub warning

##---------------------------------------------------------------------------------------------------
## debug()
##   print debug statement if debug mode is on
##---------------------------------------------------------------------------------------------------
sub debug {
  &$debug_handle(@_);
}                               # sub debug

##---------------------------------------------------------------------------------------------------
## default_info()
##   print info statement
##---------------------------------------------------------------------------------------------------
sub default_info {
  print "${prefix_char}I-${prefix}: ", @_, "\n";
}                               # sub default_info

##---------------------------------------------------------------------------------------------------
## default_error()
##   print error statement
##---------------------------------------------------------------------------------------------------
sub default_error {
  print "${prefix_char}E-${prefix}: ", @_, "\n";
}                               # sub default_error

##---------------------------------------------------------------------------------------------------
## default_fatal_error()
##   print error statement and exit with failure status
##---------------------------------------------------------------------------------------------------
sub default_fatal_error {
  die "${prefix_char}E-${prefix}: ", @_, "\n";
}                               # sub default_fatal_error

##---------------------------------------------------------------------------------------------------
## default_warning()
##   print warning statement
##---------------------------------------------------------------------------------------------------
sub default_warning {
  print "${prefix_char}W-${prefix}: ", @_, "\n";
}                               # sub default_warning

##---------------------------------------------------------------------------------------------------
## default_debug()
##   print debug statement if debug mode is on
##---------------------------------------------------------------------------------------------------
sub default_debug {
  return unless (&is_debug());
  print "${prefix_char}D-${prefix}: ", @_, "\n";
}                               # sub default_debug

##---------------------------------------------------------------------------------------------------
## default_prefix_info()
##   print info statement
##---------------------------------------------------------------------------------------------------
sub default_prefix_info {
  print &prefix_lines("${prefix_char}I-${prefix}: ", @_);
}                               # sub default_prefix_info

##---------------------------------------------------------------------------------------------------
## default_prefix_error()
##   print error statement
##---------------------------------------------------------------------------------------------------
sub default_prefix_error {
  print &prefix_lines("${prefix_char}E-${prefix}: ", @_);
}                               # sub default_prefix_error

##---------------------------------------------------------------------------------------------------
## default_prefix_fatal_error()
##   print error statement and exit with failure status
##---------------------------------------------------------------------------------------------------
sub default_prefix_fatal_error {
  die &prefix_lines("${prefix_char}E-${prefix}: ", @_);
}                               # sub default_prefix_fatal_error

##---------------------------------------------------------------------------------------------------
## default_prefix_warning()
##   print warning statement
##---------------------------------------------------------------------------------------------------
sub default_prefix_warning {
  print &prefix_lines("${prefix_char}W-${prefix}: ", @_);
}                               # sub default_prefix_warning

##---------------------------------------------------------------------------------------------------
## default_prefix_debug()
##   print debug statement if debug mode is on
##---------------------------------------------------------------------------------------------------
sub default_prefix_debug {
  return unless (&is_debug());
  print &prefix_lines("${prefix_char}D-${prefix}: ", @_);
}                               # sub default_prefix_debug

##---------------------------------------------------------------------------------------------------
## Creates a string that is made up of the input array of strings, but
## prefixed with the desired string.
## Pass in an array of strings and it will prefix all the lines with the prefix
## you want and put \n at the end of every line
##---------------------------------------------------------------------------------------------------
sub prefix_lines {
  my ($prefix, @lines) = @_;
  my $retstr = "";

  foreach my $line (@lines) {
    my @parts = split(/(\n)/, $line);
    while (@parts) {
      my $text = shift(@parts);
      $retstr .= "${prefix}${text}\n";
      shift(@parts);
    }
  }
  return $retstr;
}                               # sub prefix_lines

##---------------------------------------------------------------------------------------------------
## are_paths_equal()
##   Checks whether two paths are equal after getting their real paths
##---------------------------------------------------------------------------------------------------
sub are_paths_equal {
  my ($path1, $path2) = @_;
  my $real_path1 = &get_realpath($path1);
  my $real_path2 = &get_realpath($path2);

  return ($real_path1 eq $real_path2);
}                               # sub are_paths_equal

##---------------------------------------------------------------------------------------------------
## get_realpath()
##   Returns the sanitized real path for a given path
##---------------------------------------------------------------------------------------------------
sub get_realpath {
  my ($path) = @_;
  my $real_path = Cwd::realpath($path);
  my $site = $ENV{SITE} || $ENV{EC_SITE};
  $real_path = &get_global_path($real_path, $site) if ($site && $real_path);
  return $real_path;
}                               # sub get_realpath

##---------------------------------------------------------------------------------------------------
## get_site_path()
##   Returns the site specific path for a given site and real path
##---------------------------------------------------------------------------------------------------
sub get_site_path {
  my ($path, $site) = @_;
  $path =~ s|/site/|/${site}/|;

  return $path;
}				# sub get_site_path

##---------------------------------------------------------------------------------------------------
## get_global_path()
##   Returns the global path for a given site-specific real path and site
##---------------------------------------------------------------------------------------------------
sub get_global_path {
  my ($path, $site) = @_;
  $path =~ s|(/nfs/)${site}(/disks/)\.?|${1}site${2}|;

  return $path;
}				# sub get_global_path

##---------------------------------------------------------------------------------------------------
## validate_path()
##   This function validates the tool path.
##   The basic idea is to check whether the $path can be reached from any of the
##   paths listed in $valid_paths_ref
##---------------------------------------------------------------------------------------------------
### NOT USED by GKUTILSsub validate_path {
### NOT USED by GKUTILS  my ($path, $valid_paths_ref, $strict_mode) = @_;
### NOT USED by GKUTILS  return !$strict_mode unless ($path);
### NOT USED by GKUTILS
### NOT USED by GKUTILS  my @path_elements = splitdir($path);
### NOT USED by GKUTILS  my $path_join = $path_elements[$#path_elements];
### NOT USED by GKUTILS  my @path_list = ($path_join);
### NOT USED by GKUTILS
### NOT USED by GKUTILS  for (my $i = $#path_elements - 1; $i >= 0; --$i) {
### NOT USED by GKUTILS    $path_join = catdir($path_elements[$i], $path_join);
### NOT USED by GKUTILS    push(@path_list, $path_join);
### NOT USED by GKUTILS  }
### NOT USED by GKUTILS
### NOT USED by GKUTILS  ## WE need to push an empty string into the list so that is checks the value
### NOT USED by GKUTILS  ## against the actual valid path.  This handles the case where the key points
### NOT USED by GKUTILS  ## not to an area under the valid_path, but rather points TO the valid_path
### NOT USED by GKUTILS  ## For example: someone has a key that just points to $MODEL_ROOT
### NOT USED by GKUTILS  ##
### NOT USED by GKUTILS  push(@path_list, "");
### NOT USED by GKUTILS
### NOT USED by GKUTILS  my $good_path = 0;
### NOT USED by GKUTILS SEARCH: foreach my $valid_name (keys %$valid_paths_ref) {
### NOT USED by GKUTILS    my $valid_path = $$valid_paths_ref{$valid_name};
### NOT USED by GKUTILS    if ((defined $valid_path) && (-d $valid_path)) {
### NOT USED by GKUTILS      foreach my $chopped_path (@path_list) {
### NOT USED by GKUTILS        my $full_valid_path = catdir($valid_path, $chopped_path);
### NOT USED by GKUTILS        if ((-e $full_valid_path) && (&are_paths_equal($path, $full_valid_path))) {
### NOT USED by GKUTILS          $good_path = $valid_name;
### NOT USED by GKUTILS          last SEARCH;
### NOT USED by GKUTILS        }
### NOT USED by GKUTILS      }
### NOT USED by GKUTILS    }
### NOT USED by GKUTILS  }
### NOT USED by GKUTILS  return $good_path;
### NOT USED by GKUTILS}                               # sub validate_path
### NOT USED by GKUTILS
### NOT USED by GKUTILS##---------------------------------------------------------------------------------------------------
### NOT USED by GKUTILS## validate_nonexistent_path()
### NOT USED by GKUTILS##   This function validates the tool path if it does not exist.
### NOT USED by GKUTILS##   The basic idea is to check whether the $path can be reached from any of the
### NOT USED by GKUTILS##   paths listed in $valid_paths_ref
### NOT USED by GKUTILS##---------------------------------------------------------------------------------------------------
### NOT USED by GKUTILSsub validate_nonexistent_path {
### NOT USED by GKUTILS  my ($path, $valid_paths_ref) = @_;
### NOT USED by GKUTILS  return 0 unless ($path);
### NOT USED by GKUTILS
### NOT USED by GKUTILS  my @path_elements = splitdir($path);
### NOT USED by GKUTILS  if (grep /^\.{2}$/, @path_elements) {
### NOT USED by GKUTILS    &warning("Up directory (..) not allowed in nonexistent paths");
### NOT USED by GKUTILS    return 0;
### NOT USED by GKUTILS  }
### NOT USED by GKUTILS
### NOT USED by GKUTILS  my $good_path = 0;
### NOT USED by GKUTILS SEARCH: foreach my $valid_name (keys %$valid_paths_ref) {
### NOT USED by GKUTILS    my $valid_path = canonpath($$valid_paths_ref{$valid_name});
### NOT USED by GKUTILS
### NOT USED by GKUTILS    if (defined $valid_path) {
### NOT USED by GKUTILS      my $check_path = '';
### NOT USED by GKUTILS      foreach my $element (@path_elements) {
### NOT USED by GKUTILS        $check_path = catdir($check_path, $element);
### NOT USED by GKUTILS        if (canonpath($check_path) eq $valid_path) {
### NOT USED by GKUTILS          $good_path = $valid_name;
### NOT USED by GKUTILS          last SEARCH;
### NOT USED by GKUTILS        }
### NOT USED by GKUTILS      }
### NOT USED by GKUTILS    }
### NOT USED by GKUTILS  }
### NOT USED by GKUTILS  return $good_path;
### NOT USED by GKUTILS}                               # sub validate_nonexistent_path
### NOT USED by GKUTILS
##---------------------------------------------------------------------------------------------------
## datadump_to_file()
##---------------------------------------------------------------------------------------------------
sub datadump_to_file
{
  my ($file, @data_dumper_args) = @_;

  local $Data::Dumper::Purity = 1; 
  local $Data::Dumper::Indent = 4; 

  ## Case insensitive sort
  local $Data::Dumper::Sortkeys = sub {
    my $hash_ref = shift;

    my @sorted_keys = sort {
      lc($a) cmp lc($b) 
    } keys(%{$hash_ref});

    return(\@sorted_keys);
  };

  open my $fh, q{>}, $file;
  print {$fh} Data::Dumper->Dump(@data_dumper_args);
  close $fh;
}


##---------------------------------------------------------------------------------------------------
## get_jobs_from_task_file()
##---------------------------------------------------------------------------------------------------
sub get_jobs_from_task_file
{
    my $task_file = shift;

    ## Read the file into a single scalar for better parsing
    my $text = q{};
    if (open my $fh, q{<}, $task_file) {
       local $/ = undef;
       $text = <$fh>;
       close $fh;
    }

    ## tokenize the file. This is a bit of a hack; really the only tokens
    ## we care about are nbjob command lines, and blocks enclosed by braces
    my @tokens = $text =~ m/
        \s*
        (
            nbjob\s+run.+?\n |   ## Grab an entire nbjob command line
            [^\s]+               ## Grab any non-whitespace chunk
        )
        \s*
    /gsx;

    ## Walk over the tokens. Whenever an open-brace { is encountered, push the
    ## block name onto the stack. For our purposes, the block name is just the
    ## token preceding the {. When we see a close-brace }, then pop the block
    ## name off the stack. In this way the stack always contains the current
    ## hierarchy of blocks.
    ##
    ## Push any tasks or jobs onto the tasks_jobs array, along with the task
    ## hierarchy needed to reach the task or job.

    my @tasks_jobs = ();
    my @block_stack = ();
    for (my $i = 0; $i <= $#tokens; $i++) {
        my $token = $tokens[$i];
        chomp($token);

        if ($token eq '{') {
            my $name = $tokens[$i - 1];
            push @block_stack, $name;

            if ($tokens[$i - 2] =~ m/(?:Designated)?Task/) {
                my @task_hier = @block_stack[0 .. $#block_stack];
                my $task_path = join("/", "", @task_hier);
                push @tasks_jobs, {
                    type => 'task',
                    path => $task_path,
                    hierarchy => \@task_hier,
                    name => $name,
                };
            }

        } elsif ($token eq '}') {
            my $popped = pop @block_stack;
            if (! $popped) {
                 print STDERR "Mismatched braces in [$task_file].\n";
                 return;
            }

        } elsif ($token =~ m/nbjob run/) {
            ## All blocks up to the "Jobs" block are pushed onto the stack as
            ## task names. The Jobs block is pushed on as 'Jobs'. We don't
            ## want that as part of the task path, so join all names excepting
            ## the final entry on the block stack
            my @task_hier = @block_stack[0 .. $#block_stack - 1];
            my $task_path = join("/", "", @task_hier);
            push @tasks_jobs, {
                type => 'job',
                path => $task_path,
                hierarchy => \@task_hier,
                command => $token,
            };
        }
    }

    if (scalar(@block_stack)) {
        ## There were some blocks that did not have corresponding close braces
        print STDERR "Mismatched braces in [$task_file].\n";
        return;
    }

    return(\@tasks_jobs);
}

##---------------------------------------------------------------------------------------------------
## get_nested_hash_value()
##
## Given a hash reference, and a priority list of keys to iterate over,
## return the value found by the first successful search of the hash.
##
## For example:
## my $timeout = &get_nested_hash_value(
##     'hash_ref' => $Models{timeout},
##     'priority_list' => [
##         [ $ENV{GK_CLUSTER}, $ENV{GK_EVENTTYPE} ],
##         [ $ENV{GK_CLUSTER}, "default" ],
##         [ $ENV{GK_CLUSTER} ],
##         [ "default" ],
##         [ ],
##     ],
##     'verbose' => 1,
## );
##---------------------------------------------------------------------------------------------------
sub get_nested_hash_value
{
    my %args = @_; 
    my $hash_ref = $args{hash_ref};
    my $priority_list = $args{priority_list};
    my $verbose = $args{verbose} // 0;
    my $scalar_only = $args{scalar_only} // 0;

    PRIORITY:
    foreach my $keys (@$priority_list) {
        my $ref = $hash_ref;
        my $key_string = join(", ", @$keys);
        foreach my $key (@$keys) {
            if ((ref($ref) eq "HASH") && exists $ref->{$key}) {
                $ref = $ref->{$key};
                next;
            }

            ## The next level of key didn't exist in the hash structure
            ## so try the search again using the next item in the priority
            ## array
            print "Checking key string [$key_string] => Failed on [$key]\n" if ($verbose);
            next PRIORITY;
        }

        ## If we require a scalar but got a reference, then try the next
        ## list of keys.
        if ($scalar_only && ref($ref)) {
            print "Checking key string [$key_string] => Failed because of reference.\n";
            next PRIORITY;
        }

        ## Walked through all keys in one of the priority lists, return
        ## that value.
        printf "Checking key string [$key_string] => Found [$ref]\n" if ($verbose);

        return($ref, $keys) if (wantarray);
        return $ref;
    }

    ## No value found..
    return;
}

##---------------------------------------------------------------------------------------------------
## get_powerusers()
##---------------------------------------------------------------------------------------------------
sub get_powerusers
{
    my @powerusers = ();

    my $powerusers_file = $main::GkConfig{powerusers_file};
    return () if (! defined($powerusers_file));

    if ($powerusers_file !~ m|^/|) {
        $powerusers_file = "$ENV{GK_CONFIG_DIR}/$powerusers_file";
    }
    return () if (! -e $powerusers_file);

    if (open my $fh, q{<}, $powerusers_file) {
  #     @powerusers = <$fh>;
  #     @powerusers = trim(@powerusers);
  #     close $fh;
  #
        while(<$fh>) 
          {      
            chomp;
            s/\#.*//;    # comments
            s/^\s+//;
            s/\s+$//;
            next if /^$/;
            push @powerusers, $_;
          }     
    }

    return @powerusers;
}

sub trim {
    my (@strings) = @_;

    foreach (@strings) {
        s/^\s+//;
        s/\s+$//;
    }

    return @strings;
}

sub is_in
{
    my ($scalar, @array) = @_;

    return 1 if grep { $scalar eq $_ } @array;
    return 0;
}

##---------------------------------------------------------------------------------------------------
## get_branch()
## Returns the current branch given git and a repository
##---------------------------------------------------------------------------------------------------
#### COMMENTED OUT BECAUSE ITS NOT USEDsub get_branch
#### COMMENTED OUT BECAUSE ITS NOT USED{
#### COMMENTED OUT BECAUSE ITS NOT USED  my ($git, $git_dir, $no_fatal) = @_;
#### COMMENTED OUT BECAUSE ITS NOT USED  my $branch;
#### COMMENTED OUT BECAUSE ITS NOT USED  my $git_command;
#### COMMENTED OUT BECAUSE ITS NOT USED  if ($git_dir) {
#### COMMENTED OUT BECAUSE ITS NOT USED    $git_command = "${git} --git-dir=${git_dir} -c color.ui=never symbolic-ref -q HEAD 2> /dev/null";
#### COMMENTED OUT BECAUSE ITS NOT USED  } else {
#### COMMENTED OUT BECAUSE ITS NOT USED    $git_command = "${git} -c color.ui=never symbolic-ref -q HEAD 2> /dev/null";
#### COMMENTED OUT BECAUSE ITS NOT USED  }
#### COMMENTED OUT BECAUSE ITS NOT USED
#### COMMENTED OUT BECAUSE ITS NOT USED  # Get the current branch
#### COMMENTED OUT BECAUSE ITS NOT USED  my @branch_list = ();
#### COMMENTED OUT BECAUSE ITS NOT USED  my $status = &run_command($git_command, \@branch_list, {timeout => 900, no_redirect => 1});
#### COMMENTED OUT BECAUSE ITS NOT USED  &debug("Command Output (Status = ${status}):\n" . join("\n", @branch_list));
#### COMMENTED OUT BECAUSE ITS NOT USED
#### COMMENTED OUT BECAUSE ITS NOT USED  if ($status) {
#### COMMENTED OUT BECAUSE ITS NOT USED    $branch = (splitdir($branch_list[0]))[-1];
#### COMMENTED OUT BECAUSE ITS NOT USED    if (!$branch) {
#### COMMENTED OUT BECAUSE ITS NOT USED      my $error_msg = "Unable to determine current branch. git results:\n" . join("\n", @branch_list);
#### COMMENTED OUT BECAUSE ITS NOT USED      &fatal_error($error_msg) unless ($no_fatal);
#### COMMENTED OUT BECAUSE ITS NOT USED      &error($error_msg);
#### COMMENTED OUT BECAUSE ITS NOT USED      $branch = undef;
#### COMMENTED OUT BECAUSE ITS NOT USED    }
#### COMMENTED OUT BECAUSE ITS NOT USED  } else {
#### COMMENTED OUT BECAUSE ITS NOT USED    my $error_msg = "Unable to determine current branch: git command failed. You are most likely not on a branch.";
#### COMMENTED OUT BECAUSE ITS NOT USED    &fatal_error($error_msg) unless ($no_fatal);
#### COMMENTED OUT BECAUSE ITS NOT USED    &error($error_msg);
#### COMMENTED OUT BECAUSE ITS NOT USED  }
#### COMMENTED OUT BECAUSE ITS NOT USED
#### COMMENTED OUT BECAUSE ITS NOT USED  return $branch;
#### COMMENTED OUT BECAUSE ITS NOT USED}

1;
