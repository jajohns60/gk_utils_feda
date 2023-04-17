#!/usr/intel/bin/perl -w
##-------------------------------------------------------------------------------
##     Package Name: VTMBTool.pm
##          Project: Haswell/Broadwell
##  Original Author: Chancellor Archie (chancellor.archie@intel.com)
##      Description: This package was original developed for CedarMill DFT Tools, and Chancellor
##                   utilized them for DA tool development. They have been leveraged to VTMB.
##                   This package is a tool object that contains utility functions.
##                  
##
##
##  (C) Copyright Intel Corporation, 2008
##  Licensed material -- Program property of Intel Corporation
##  All Rights Reserved
## 
##  This program is the property of Intel Corporation and is furnished
##  pursuant to a written license agreement. It may not be used, reproduced,
##  or disclosed to others except in accordance with the terms and conditions
##  of that agreement
##-------------------------------------------------------------------------------

#--------------------------------------------------------------------------------
# Package Info
#--------------------------------------------------------------------------------
package VTMBTool; # Package name

#--------------------------------------------------------------------------------
# Required Libraries
#--------------------------------------------------------------------------------
use strict;         # Use strict syntax pragma
use VTMBObject;

#--------------------------------------------------------------------------------
# Object Inheritance 
#--------------------------------------------------------------------------------
use vars qw(@ISA);
@ISA = qw(VTMBObject);


#--------------------------------------------------------------------------------
# new(hash of initial property values)
#   Object Constructor which will override VTMBObject 
#--------------------------------------------------------------------------------
sub new 
{
  my $class = shift;   
  my $self;

  # Initialize object properties and override with user values if specified.
  $self = {
            BREAKPOINT        => undef,
            CMDLINEOBJ        => undef, 
            COMMAND_ECHO      => 0, 
            DEBUG             => 0, 
            ERROR_COUNT       => 0, 
            EXIT_CODE         => 0, 
            EXIT_FUNC         => undef, 
            LOGOBJ            => undef, 
            MSG_INDENT        => 0, 
            NAME              => undef, 
            QUIET             => 0, 
            STARTTIME         => time(), 
            SUPPRESS_ERRORS   => 0, 
            VERSION           => undef, 
            WARNING_COUNT     => 0, 
            WARNING_PROMPT    => 0,
            TOOL_MSG_SUPPRESS => 0,
            STDOUT_BEFORE_LOG => undef,
            @_,
          }; 
  # Check if Name is set.
  unless (defined $self->{'NAME'})
    {
       return undef;
     }
  # Bless the reference and return it
  bless $self, $class;
  return $self;
}

#--------------------------------------------------------------------------------
# check_environment(@requied,@optional)
#   Verifies that environment variables have been set and returns what is used
#--------------------------------------------------------------------------------
sub check_environment
{
  # Get class type, required, and optional list of environment settings
  my ($self,$objrefReq,$objrefOpt) = @_;

  # Save Environment variables which are Set.
  my @used;

  # Verify Required Environment Variables are defined.
  foreach (@$objrefReq)
   {
     if(exists $ENV{"$_"})
      {
        # Display Save each set env var
        push @used, $_  . '=' . $ENV{"$_"};
        $self->info('$' . $_ . ' = ' . $ENV{"$_"});
      }
     else
      {
        # Display error message
        $self->error("Required environment variable \$$_ must be defined for this tool");
      }
   }

   # Check which optional environment variables have been used
   foreach (@$objrefOpt)
    {
     if(exists $ENV{"$_"})
       {
         # Display value of each variable
         $self->info('$' . $_ . ' = ' . $ENV{"$_"});
         push(@used, $_ . ' = ' . $ENV{"$_"});
       }
      else
       {
         # Display info message
         $self->info("Optional environment variable \$$_ is not defined");
       }
     }
         
     # Return list of name/value pairs of used environment variables
     return @used;
}

#---------------------------------------------------------------------------------------------------
# blank(msg)
#   Displays blank line on screen and log file
#---------------------------------------------------------------------------------------------------
sub blank
{
    # Get class type
    my $self = shift;

    # Display to STDOUT unless QUIET
    print "\n" unless ($self->{'QUIET'});
    
    # Write to log file if using
    if ($self->{'LOGOBJ'})
    {
        $self->{'LOGOBJ'}->write("\n");
    }
}
#---------------------------------------------------------------------------------------------------
# check_errors(msg)
#   Terminates tool if an error has occurred
#---------------------------------------------------------------------------------------------------
sub check_errors
{
    # Get class type
    my $self = shift;

    # Terminate tool if ERROR_COUNT > 0
    if ($self->{'ERROR_COUNT'} > 0)
    {
        $self->{'EXIT_CODE'} = 1 if ($self->{'EXIT_CODE'} == 0);
        $self->terminate();
    }
}

#---------------------------------------------------------------------------------------------------
# checksum(path)
#   Uses to "cksum" system command and returns CRC checksum of file
#---------------------------------------------------------------------------------------------------
sub checksum
{
    # Get class type and path
    my ($self, $path,$unzipfirst) = @_;

    # Calcaulte checksum of file, if cksum program found
    if (-x "/usr/bin/cksum")
    {
        # Use GNU utility 'cksum' to calculate CRC of file
        my $cmd = "/usr/bin/cksum $path";
        my @results;

        if($unzipfirst)
        {
	  $cmd = "gzcat $path | /usr/bin/cksum";
        }

        # Use 'cksum' tool
        @results = `$cmd`;

        # Parse output of cksum command
        my $chksum = 0;
        foreach (@results)
        {
            # Skip blank lines
            next if (/^\s*$/);

            # Look for line containing checksum
            if (/^(\d+)\s+\d+\s+/)
            {
                $chksum = $1;
            }
        }

        # Display message if no checksum found
        if ($chksum == 0)
        {
            $self->warning("Could not generate checksum for $path because cksum program gave unexpected output for cmd '$cmd'. Results: @results");
        }
        
        return $chksum;
    }
    else
    {
        $self->warning("Cannot generate checksum for $path because cksum program not found");
        return 0;
    }                           
}


#---------------------------------------------------------------------------------------------------
# clear_errors()
#   Resets error count to 0
#---------------------------------------------------------------------------------------------------
sub clear_errors
{
    # Get class type
    my $self = shift;

    $self->{'ERROR_COUNT'} = 0;
}


#---------------------------------------------------------------------------------------------------
# command(msg)
#   Displays sub tool commands and results
#---------------------------------------------------------------------------------------------------
sub command
{
    # Get class type, and message
    my ($self, $msg) = @_;

    # Add tool name and type and indent to message
    $msg = $self->{'NAME'} . " -C- " . " " x $self->{'MSG_INDENT'} . "$msg\n";

    # Display to STDOUT only if SHOW_COMMANDS = 1 and !QUIET
    print $msg if ($self->{'COMMAND_ECHO'} and !$self->{'QUIET'});
    
    # Write to log file if using
    if ($self->{'LOGOBJ'})
    {
        $self->{'LOGOBJ'}->write($msg);
    }
}

#---------------------------------------------------------------------------------------------------
# confirm(msg)
#   Calls warning() unless warning prompt is disabled in which case it calls fatal()
#---------------------------------------------------------------------------------------------------
sub confirm
{
    # Get class type, and message
    my ($self, $msg) = @_;

    # Determine message type
    if ($self->{'WARNING_PROMPT'})
    {
        $self->warning($msg);
    }
    else
    {
        $self->fatal($msg);
    }
}


#---------------------------------------------------------------------------------------------------
# copyfile(src, dst)
#   Uses to "cp" system command to copy a file and handles errors
#---------------------------------------------------------------------------------------------------
sub copyfile
{
    # Get class name, source path, and destination path
    my ($self, $src, $dst) = @_;

    # Verify that source file exists
    unless (-e $src) 
    {
        $self->error("Attempted to copy nonexistant file $src");   
    }
    
    # Try to copy file and handle possible error
    my (@results);
    $self->run("cp $src $dst", \@results);

    # Verify that destination file now exists
    unless (-e $dst) 
    {
        $self->error("cp command filed, destination file doesn't exist at $dst");
        return 0;
    }

    return 1;
}    


#---------------------------------------------------------------------------------------------------
# create_directories(path)
#   Create necessary subdirectories to get to path
#---------------------------------------------------------------------------------------------------
sub create_directories
{
    # Get class name
    my $self = shift;
    
    # Return undef if invalid parameter passed
    unless (scalar @_ == 1 && $_[0] =~ /^\//)
    {
        $self->error("Invalid arguments passed to create_directories.  Report error to DA.");
        return undef;
    }
    
    # Create subdirectories if needed
    my @dirs = split(/\//, $_[0]);
    
    # Drop first element (it's blank)
    shift @dirs;
    
    for (my $i=0; $i<=$#dirs; $i++)
    {
        my $subdir = '/' . join('/', @dirs[0..$i]);
        unless (-d $subdir)
        {
            $self->debug("Creating the directory $subdir");
            mkdir $subdir, 0770 or $self->fatal("Could not create directory $subdir");
        }
    }
    
    return 1;
}


#---------------------------------------------------------------------------------------------------
# debug(msg)
#   Displays debug message if debug mode is on
#---------------------------------------------------------------------------------------------------
sub debug
{
    # Get class type, and message
    my ($self, $msg) = @_;

    # Only show if DEBUG=1
    if ($self->{'DEBUG'} == 1)
    {
        # Add tool name and type and indent to message
        $msg = $self->{'NAME'} . " ($$) -D- " . " " x $self->{'MSG_INDENT'} . "$msg\n";

        # Display to STDOUT unless QUIET
        print $msg unless ($self->{'QUIET'});

        # Write to log file if using
        if ($self->{'LOGOBJ'})
        {
            $self->{'LOGOBJ'}->write($msg);
        }
    }
}


#---------------------------------------------------------------------------------------------------
# deletefile(src)
#   Uses to "rm -f" system command to delete a file and handles errors
#---------------------------------------------------------------------------------------------------
sub deletefile
{
    # Get class name, source path
    my ($self, $src) = @_;

    # Verify that source file exists
    unless (-e $src or -l $src) 
    {
        $self->error("Attempted to delete nonexistant file $src");   
    }
    
    # Try to move file and handle possible error
    my (@results);
    if ($self->run("rm -f $src", \@results) > 0) {
    
        # Display error message and return false
        unshift(@results, 'rm command failed, error message:');
        $self->error(join("\n  ", @results));  
        return 0;
    }
    else
    {
        # Verify that source file does not exist
        if (-e $src or -l $src) 
        {
            $self->error("rm command filed, source file still exists at $src");    
            return 0;
        }
    }

    return 1;
}    


#---------------------------------------------------------------------------------------------------
# error(msg)
#   Displays error message
#---------------------------------------------------------------------------------------------------
sub error
{
    # Get class type, and message
    my ($self, $msg) = @_;

    # If errors are being supressed, route them to warning instead
    if($self->{'SUPPRESS_ERRORS'})
    {
	$self->warning($msg);
        return;
    }

    # Add tool name and type and indent to message
    if($self->{TOOL_MSG_SUPPRESS})
     {
       $msg = " " x $self->{'MSG_INDENT'} . "$msg\n";
     }      
    else
     { 
       $msg = $self->{'NAME'} . " -E- " . " " x $self->{'MSG_INDENT'} . "$msg\n";
     }

    # Display to STDOUT
    print $msg;
    
    # Write to log file if using
    if ($self->{'LOGOBJ'})
    {
        $self->{'LOGOBJ'}->write($msg);
    }
    
    # Increment error count
    $self->{'ERROR_COUNT'}++;
}


#---------------------------------------------------------------------------------------------------
# fatal(msg)
#   Displays fatal message and terminates tool immediately
#---------------------------------------------------------------------------------------------------
sub fatal
{
    # Get class type, and message
    my ($self, $msg) = @_;

    # Add tool name and type and indent to message
    $msg = $self->{'NAME'} . " -F- " . " " x $self->{'MSG_INDENT'} . "$msg\n";

    # Display to STDOUT
    print $msg;
    
    # Write to log file if using
    if ($self->{'LOGOBJ'})
    {
        $self->{'LOGOBJ'}->write($msg);
    }
    
    # Increment error count
    $self->{'ERROR_COUNT'}++;
    
    # Terminate the tool
    $self->{'EXIT_CODE'} = 1 if ($self->{'EXIT_CODE'}==0);
    $self->terminate;
}


#---------------------------------------------------------------------------------------------------
# free_disk_space(directory, MB required)
#   Returns the amount of free disk space in the current directory (in megabytes).  If "directory"
#   parameter is supplied, gets free space in that directory instead.  If "MB required" parameter is
#   supplied, returns 1 if that much in available or 0 otherwise.
#---------------------------------------------------------------------------------------------------
sub free_disk_space
{

    # Get class type, directory, MB required
    my ($self, $dir, $gb_required) = @_;

    # Default values for optional arguments
    $dir = "." unless (defined $dir);

    # Use "df" to determine current free space.
    # -k => use 1024 byte blocks
    # -P => use posix output format, for consistent SLES10/SLES11 output
    # Sample output:
    # Filesystem         1024-blocks      Used Available Capacity Mounted on
    # fmnap2037b:/vol/vol0/fm_cse_10745  22020096  14389632   7630464      66% /nfs/fm/disks/fm_cse_10745
    my @results      = `df -k -P $dir`;
    my $gb_available = -1;
    if (! $?) {
        my @split = split /\s+/, $results[-1];

        ## convert kilobytes to gigabytes
        $gb_available = $split[3] / 1024 / 1024;
    }

    if ($gb_available == -1) {
        $self->info("Could not determine free disk space on directory $dir");
        return 0;
    }

    $self->debug("TCGTool::free_disk_space() $gb_available GB free on $dir");

    # Was GB required supplied?
    if (defined $gb_required) {
        return ($gb_required < $gb_available);
    }

    # Otherwise return free MB
    return $gb_available;
}


#---------------------------------------------------------------------------------------------------
# identify()
#   Returns tool identification string
#---------------------------------------------------------------------------------------------------
sub identify
{
    # Get class type
    my $self = shift;
    
    # Return tool name, version, and path
    return $self->get('NAME') . ' ' . $self->get('VERSION') . " $0";
}


#---------------------------------------------------------------------------------------------------
# indent_msg(value)
#   Indents all future messages by "value" spaces or resets indent if value = 0
#---------------------------------------------------------------------------------------------------
sub indent_msg
{
    # Get class type and value
    my ($self, $value) = @_;
    
    # Reset indent if value = 0
    if ($value == 0)
    {
        $self->{'MSG_INDENT'} = 0;
    }
    
    # Otherwise increase/descrease indent by value
    else
    {
        $self->{'MSG_INDENT'} += $value;
    }
    
    # Return current value of indent
    return $self->{'MSG_INDENT'};
}


#---------------------------------------------------------------------------------------------------
# info(msg)
#   Displays informational message
#---------------------------------------------------------------------------------------------------
sub info
{
    # Get class type, and message
    my ($self, $msg) = @_;

    # Add tool name and type and indent to message
    if($self->{TOOL_MSG_SUPPRESS})
     {
       $msg = " " x $self->{'MSG_INDENT'} . "$msg\n";
     }       
    else
     {
       $msg = $self->{'NAME'} . " -I- " . " " x $self->{'MSG_INDENT'} . "$msg\n";
     }       

    # Display to STDOUT unless QUIET
    print $msg unless ($self->{'QUIET'});
    
    # Write to log file if using
    if ($self->{'LOGOBJ'})
    {
        $self->{'LOGOBJ'}->write($msg);
    }
   else
    {
        if(!defined $self->{STDOUT_BEFORE_LOG})
         {
            $self->set('STDOUT_BEFORE_LOG',$msg);
         }
        else
         {
            $self->set('STDOUT_BEFORE_LOG',"$self->{'STDOUT_BEFORE_LOG'}:space:$msg");
         } 
    
    }  
}


#---------------------------------------------------------------------------------------------------
# log(msg)
#   Displays message to log file only
#---------------------------------------------------------------------------------------------------
sub log
{
    # Get class type, and message
    my ($self, $msg) = @_;

    # Add tool name and type and indent to message
    $msg = $self->{'NAME'} . " -L- " . " " x $self->{'MSG_INDENT'} . "$msg\n";

    # Write to log file if using
    if ($self->{'LOGOBJ'})
    {
        $self->{'LOGOBJ'}->write($msg);
    }
}


#---------------------------------------------------------------------------------------------------
# movefile(src, dst)
#   Uses to "mv -f" system command to move a file and handles errors
#---------------------------------------------------------------------------------------------------
sub movefile
{
    # Get class name, source path, and destination path
    my ($self, $src, $dst) = @_;

    # Verify that source file exists
    unless (-e $src) {
        $self->error("Attempted to move nonexistant file $src");   
        return 0;
    }
    
    # Try to move file and handle possible error
    my (@results);
    if ($self->run("mv -f $src $dst", \@results) > 0) {
    
        # Display error message and return false
        unshift(@results, 'mv command failed, error message:');
        $self->error(join("\n  ", @results));  
        return 0;
    }
    else
    {
        # Verify that destination file now exists and source file does not
        unless (-e $dst) {
            $self->error("mv command filed, destination file doesn't exist at $dst");
            return 0;
        }
        if (-e $src) {
            $self->error("mv command filed, source file still exists at $src");    
            return 0;
        }
    }

    return 1;
}    


#---------------------------------------------------------------------------------------------------
#  rename_existing(path)
#    Generate warning and rename file if it exists
#---------------------------------------------------------------------------------------------------
sub rename_existing
{
    # Get classname, path to file
    my ($self, $path) = @_;

    # If file exists ...
    if (-e $path)
    {
        # Determine unique name for file
        my $num = 1;
        while (-e "$path.prev.$num")
        {
            $num++;
        }
        $self->warning("Existing file ($path) will be renamed to $path.prev.$num");
        $self->movefile($path, "$path.prev.$num");
        $self->check_errors();
    }
    
    # Success
    return $path;
}

#---------------------------------------------------------------------------------------------------
# system_piped_call(command line, results array)
#   Executes the command and returns the result in an array
#   This should execute quicker than backtick operations... 
#   -Dani
#---------------------------------------------------------------------------------------------------
sub system_piped_call 
{
    # Get class name, command line, and array reference if it exists
    my ($self, $cmd, $aryref) = @_;
    chomp($cmd);

    open(P, "-|","$cmd") or $self->error("Can't fork in system_piped_call(): $!");
    while (<P>) {
        push @$aryref,$_;
    }
    close(P) or $self->error("Bad pipe occurred in system_piped_call(): $! $?");

    my $return_value = $? >> 8;
    $self->debug("Exit status was $?");
    return $return_value;;

}

#---------------------------------------------------------------------------------------------------
# run(command line, results array)
#   Executes the command and returns the result in an array
#---------------------------------------------------------------------------------------------------
sub run
{
    # Get class name, command line, and array reference if it exists
    my ($self, $cmd, $aryref, @results);
    my $suppress_output=0;
    if (scalar(@_) == 2) 
    {
        ($self, $cmd) = @_;
        $aryref = undef;
    }
    elsif (scalar(@_) == 3)
    {
        ($self, $cmd, $aryref) = @_;
    }
    elsif (scalar(@_) == 4)
    {
        ($self, $cmd, $aryref,$suppress_output) = @_;
    }
    else
    {
        return undef;
    }
    
    # Temporarily disable SIGCHLD
    local $SIG{'CHLD'} = 'DEFAULT';
    
    # Execute command and save results
    $self->debug("Executing cmd: '$cmd'");
    $self->command($cmd);
    @results = `$cmd 2>&1`;
	my $return_value = $? >> 8;
    if($suppress_output==0)
     {
       $self->debug('Results of command: ' . join(" ",@results));
     }
    else
     {
       $self->debug('Suppressing output to STDOUT for: ' . $cmd);
     }
    
    # Return results if array reference supplied
    if (defined($aryref)) 
    {
        @$aryref = @results;
    }

    # Return result of the command
    $self->debug("Exit status was $?");
    return $return_value;;
}
    

#---------------------------------------------------------------------------------------------------
# runbg(command line)
#   Executes the command in background and returns immediately
#---------------------------------------------------------------------------------------------------
sub runbg
{
    # Get class name, command line
    my ($self, $cmd);
    if (scalar(@_) == 2) 
    {
        ($self, $cmd) = @_;
    }
    else
    {
        return undef;
    }
    
    # Execute command in background
    $cmd .= " &";
    $self->command($cmd);
    my $code = system($cmd);

    # Return result of the command
    return $code;
}

#---------------------------------------------------------------------------------------------------
# runint(command line, job ID,autolaunch?)
#   Stores the command in a shell script and instructs the user
#---------------------------------------------------------------------------------------------------
sub runint
{
    # Get class name, command line, jobid
    my ($self, $cmd, $jobid, $autolaunch);
    if (scalar(@_) == 3)
    {
        ($self, $cmd, $jobid) = @_;
    }
    elsif (scalar(@_) == 4)
    {
        ($self, $cmd, $jobid, $autolaunch) = @_;
    }
    else
    {
        return undef;
    }
    
    # Make sure $WORK_AREA_ROOT_DIR exists
    if (!exists $ENV{'WORK_AREA_ROOT_DIR'})
    {
        $self->fatal("The \$WORK_AREA_ROOT_DIR environment variable must be set to run interactive jobs");
    }
    
    # Store command into shell script
    open(JF, ">$ENV{'WORK_AREA_ROOT_DIR'}/$jobid.tcsh") or $self->fatal("Could not open $jobid.tcsh for writing ($!)");
    print JF "#!/bin/tcsh\n\n";
    print JF "$cmd\n";
    close(JF);
    
    # Give it execute permission
    `chmod +x $ENV{'WORK_AREA_ROOT_DIR'}/$jobid.tcsh`;
    
    if (defined $autolaunch and $autolaunch == 1)
    {
        # Launch command in new window
        `xterm  -T $jobid -e $ENV{'WORK_AREA_ROOT_DIR'}/$jobid.tcsh &`;
    }
    else
    {
        # Display message instructing user
        $self->info("To start your interactive run, type ./$jobid.tcsh and press <ENTER> at the command line");
    }
    
    # Return success
    return 0;
}


#---------------------------------------------------------------------------------------------------
# runtime()
#   Returns elapsed time since tool began execution
#---------------------------------------------------------------------------------------------------
sub runtime
{
    # Get class type
    my $self = shift;
    
    # Return current run time of tool
    return (time() - $self->{'STARTTIME'});
}


#---------------------------------------------------------------------------------------------------
# symlink(src, dst)
#   Uses to "ln -s" system command to create a symbolic link to src
#---------------------------------------------------------------------------------------------------
sub symlink
{
    # Get class name, source path, and destination path
    my ($self, $src, $dst) = @_;

    # Verify that source file exists
    unless (-e $src) {
        $self->error("Attempted to link to nonexistant file $src");   
    }
    
    # Try to move file and handle possible error
    my (@results);
    if ($self->run("ln -s $src $dst", \@results) > 0) {
    
        # Display error message and return false
        unshift(@results, 'ln command failed, error message:');
        $self->error(join("\n  ", @results));  
        return 0;
    }
    #else
    #{
    #    # Verify that destination file now exists and source file does not
    #    unless (-l $dst) {
    #        $self->error("ln command filed, destination file doesn't exist at $dst");
    #        return 0;
    #    }
    #}

    return 1;
}       


#---------------------------------------------------------------------------------------------------
# terminate()
#   Object pre-destructor closes log file and exits with status
#---------------------------------------------------------------------------------------------------
sub terminate
{
    # Get class type
    my $self = shift;
    $self->debug('Terminating the tool');
    
    # Reset indent
    $self->{'MSG_INDENT'} = 0;
    
    # Write out error and warning count
    $self->info('Encountered ' . $self->{'ERROR_COUNT'} . ' errors, ' . $self->{'WARNING_COUNT'} . ' warnings');

    # Write out run time of the tool
    $self->info('Run time was ' . $self->runtime() . ' seconds');

    # Close log object if there was one
    if (defined $self->{'LOGOBJ'})
    {
        $self->{'LOGOBJ'}->closelog();
    }

    # If exit function registered, use it
    if (defined $self->{'EXIT_FUNC'})
    {
        $self->debug('Calling exit function');
        &{$self->{'EXIT_FUNC'}}($self->{'EXIT_CODE'});
    }
    
    # Otherwise exit with current exit code
    else
    {
        exit $self->get('EXIT_CODE');
    }
}


#---------------------------------------------------------------------------------------------------
# warning(msg)
#   Displays warning message and prompts to continue
#---------------------------------------------------------------------------------------------------
sub warning
{
    # Get class type, and message
    my ($self, $msg) = @_;

    # Add tool name and type and indent to message
    if($self->{TOOL_MSG_SUPPRESS})
     {
       $msg = " " x $self->{'MSG_INDENT'} . "$msg\n";
     }      
    else
     {
       $msg = $self->{'NAME'} . " -W- " . " " x $self->{'MSG_INDENT'} . "$msg\n";
     }

    # Display to STDOUT
    print $msg;
    
    # Write to log file if using
    if ($self->{'LOGOBJ'})
    {
        $self->{'LOGOBJ'}->write($msg);
    }
    
    # Increment warning count
    $self->{'WARNING_COUNT'}++;
    
    # Prompt user to continue if WARNING_PROMPT=1
    if ($self->{'WARNING_PROMPT'} == 1)
    {
        # Repeat question until valid answer is given
        my $prompt = '';
        while ($prompt eq '')
        {
            print "Do you wish to continue (y/n)? ";
            $prompt = lc <STDIN>;
            chomp $prompt;
            unless ($prompt =~ /^y/ || $prompt =~ /^n/)
            {
                $prompt = '';
            }
        }
        
        # Terminate the tool if answer was no
        if ($prompt =~ /^n/)
        {
            $self->{'EXIT_CODE'} = 2 if ($self->{'EXIT_CODE'}==0);
            $self->terminate();
        }
    }
}
###---------------------------------------------------------------------------------------------------
### write_report()
###   Write GK report 
###---------------------------------------------------------------------------------------------------
sub write_report
{
   my ($self,$objRef,$report_file) = @_;
   my ($report_csv);
   $report_csv = $report_file;
   $report_csv =~ s/txt/csv/;
   # Turn Job object
   my $jobs;
   my $date = `date`;
   chomp($date); 

   # Report Rows, Headers
   my $i = 0;
   my $reasons = 0; 
   my @reasons_array;
   my @report_rows;
   my @report_headers =("Jobs ",
                        "Status ",
                        "Wait Reason ",
                        "Wait Local ",
                        "Wait Remote ",
                        "Running ",
                        "Passing ",
                        "Failing ",
                        "Skipped ",
                        "Failures ");

   open(CSV,">$report_csv"); 
   print CSV "Job Desc,Status,Start Time,End Time\n";
   # Put Together Job Table
   foreach $jobs (@$objRef) 
    {
      if(!defined $jobs->{PARENT_TASK}) 
       {
          # Job Name
         #$report_rows[$i][0] = $jobs->{NAME};
          $report_rows[$i][0] = $jobs->{DESC};  # Job
    
          # Initialize Columns
          $report_rows[$i][2] = "";             # Waiting Reason
          $report_rows[$i][3] = "";             # Waiting Local
          $report_rows[$i][4] = "";             # Waiting Remote
          $report_rows[$i][5] = "";             # Running
          $report_rows[$i][6] = "";             # Passing
          $report_rows[$i][7] = "";             # Failing
          $report_rows[$i][8] = "";             # Skipped
          $report_rows[$i][9] = "";             # Reason
    
          # Job Status
          if(defined $jobs->{STATUS})
           {  
             $report_rows[$i][1] = $jobs->{STATUS} . " ";
           }
          elsif(defined $jobs->{NB_STATUS})
           {
             $report_rows[$i][1] = $jobs->{NB_STATUS} . " ";
           }
          else
           {
             $report_rows[$i][1] = "TASK NOT ACCEPTED BY NBFEEDER";
             $jobs->{NB_STATUS} = $report_rows[$i][1] . " ";
           }
          # Jobs Waiting( Reason,Local, & Remote)
          if((defined $jobs->{WAIT_REASON}) && ($jobs->{WAIT_REASON} ne 0))
           {
             $report_rows[$i][2] = $jobs->{WAIT_REASON} . " ";
           }
          if((defined $jobs->{WAIT_LOCAL}) && ($jobs->{WAIT_LOCAL} ne 0))
           {
             $report_rows[$i][3] = $jobs->{WAIT_LOCAL} . " ";
           }
          if((defined $jobs->{WAIT_REMOTE}) && ($jobs->{WAIT_REMOTE} ne 0))
           {
             $report_rows[$i][4] = $jobs->{WAIT_REMOTE} . " ";
           }
    
          # Jobs Running
          if((defined $jobs->{RUNNING}) && ($jobs->{RUNNING} ne 0))
           {
             $report_rows[$i][5] = $jobs->{RUNNING} . " ";
           }
    
          # Jobs Passing
          if((defined $jobs->{PASSING}) && ($jobs->{PASSING} ne 0))
           {
             $report_rows[$i][6] = $jobs->{PASSING} . " ";
           }
    
          # Jobs Failing but Not Gating
          if((defined $jobs->{FAILING}) && ($jobs->{FAILING} ne 0) && (!$jobs->{GATING}))
           {
             $report_rows[$i][7] = $jobs->{FAILING} . " ";
           }

          # Jobs Passing
          if((defined $jobs->{SKIPPED}) && ($jobs->{SKIPPED} ne 0))
           {
             $report_rows[$i][8] = $jobs->{SKIPPED} . " ";
           }

          # Jobs Failing but Gating
          if((defined $jobs->{FAILING}) && ($jobs->{FAILING} ne 0) && ($jobs->{GATING}))
           {
             $report_rows[$i][7] = $jobs->{FAILING} . " ";
    
             # Failure Reasons
             if($jobs->{NB_STATUS} ne "Submitted")
              {
                $report_rows[$i][9] = $reasons;
                # Add the Failure log file to Array
                if(defined $jobs->{RPT_FILE})
                 {
                   push @reasons_array, $jobs->{RPT_FILE};
                 }
                else
                 {
                   push @reasons_array, $jobs->{LOG_FILE} if(defined $jobs->{LOG_FILE});
                 }
                # Increment a Failure Reason Count
                $reasons++;
              }
           
                if (defined $jobs->{REGRESS_NB_OUTPUT}) {
                    my $regress_nb_output = $jobs->{REGRESS_NB_OUTPUT};
                    push @reasons_array, $regress_nb_output;
                   # $self->info("Regress NB output for the failed jobs can be found at: @reasons_array\n");
                }

}
    
    
    
          # Print each line to CSV File
          if (defined $jobs->{NB_START_TIME} && defined $jobs->{NB_END_TIME}) 
          {
             print CSV "$report_rows[$i][0],$report_rows[$i][1],$jobs->{NB_START_TIME},$jobs->{NB_END_TIME}\n";
          }
          else
          {
               print CSV "$report_rows[$i][0],$report_rows[$i][1],N/A,N/A\n";
          }
    
          # Increment
          $i++; 
       }
    }

   # Print Table
   &print_table($report_file,\@reasons_array,\@report_headers, @report_rows);
   close(CSV);

}

#-------------------------------------------------------------------------------
# table_func()     
#   Creates Table give array of Header and Rows 
#-------------------------------------------------------------------------------
sub print_table
{
   # Used for Table Stuff, move to object Later.
   use Text::Wrap;
   use Term::Size;

   my ($report_file,$fail_reasons,$header, @rows) = @_;
   my $i;
   my $date = `date`;
   chomp($date);

   my ($t_header, $t_divider, @t_rows) = &table($header, @rows);

   # PRint the Table 
   open(GK_REPORT,">$report_file");
   print GK_REPORT "\n\t\t $date\n\n";
   print GK_REPORT "$t_header\n$t_divider\n";
   print GK_REPORT (join("\n", @t_rows), "\n\n");
   if(defined $$fail_reasons[0])
    {
      print GK_REPORT "Failure Reports/Log Files:\n";
      print GK_REPORT "--------------------------\n";
      for($i=0;$i<@$fail_reasons;$i++)
       {
         if ($$fail_reasons[$i] !~ /\S+\s+\S+/) 
          { 
            print GK_REPORT "$i -- $$fail_reasons[$i]\n";             
          }
         else 
          {
            my @all_reasons = split (/ /, $$fail_reasons[$i]);
            foreach my $res (@all_reasons) 
             {
                next unless job_failed($res); 
                print GK_REPORT "$i -- $res\n";
             }   
          }
                  
       } 
    } 
   print GK_REPORT "\nGK Work Area:\n";
   print GK_REPORT "--------------\n";
   print GK_REPORT "$ENV{'MODEL'}\n";
   close(GK_REPORT);

}

# Look for the exist status in the log file to figure out if it failed
sub job_failed 
{
   my $nblog = shift;
   return 0 unless -e $nblog;
   my $res = `tail -12 $nblog | grep 'Exit Status' | grep ': 0'|wc -l`;
   chomp $res;
   return ($res == 1) ? 0 : 1;
}

sub table
{
    my ($header, @rows) = @_;
    my $max_col = scalar(@$header) - 1;
    our ($opt_l);

    ## set up initial maximum field widths
    my ($field);
    my (@format_strings);
    my (@max_len, @divider);

    my ($term_cols, $term_rows) = &Term::Size::chars(*STDOUT);
    $term_cols = 220 if (! $term_cols);

    my ($i);
    for ($i = 0; $i <= $max_col; $i++) {
        $max_len[$i] = length($header->[$i]);

        foreach my $row (@rows) {

            ## remove any newlines from the data
            $row->[$i] =~ s/\n/,/g;

            $max_len[$i] = length($row->[$i])
                if (length($row->[$i]) > $max_len[$i]);
        }
    }

    my $total_width = 0;
    for ($i = 0; $i <= $max_col; $i++) {
        $total_width += 1 + $max_len[$i];
    }

    $max_len[$max_col] = $term_cols - ($total_width - $max_len[$max_col])
        if ($total_width > $term_cols);

    for ($i = 0; $i <= $max_col; $i++) {
        if($i==0) # First column should be left Justified
         {
           push @format_strings, "%-$max_len[$i]s";
         }
        else
         {
           push @format_strings, "%$max_len[$i]s";
         }
        push @divider, "-" x $max_len[$i];
    }

    my $format_string = join("|", @format_strings);
    my $header_string = sprintf($format_string, @$header);
    my $divider_string = join(" ", @divider);

    my ($wrapped_rows, @extra_rows, $wrap_prefix_len);
    $Text::Wrap::columns = $term_cols;
    $wrap_prefix_len = $term_cols - $max_len[$max_col] - 1;

    my @row_strings = ();
    foreach my $row (@rows) {
        @extra_rows = ();

        # trim leading whitespace
        $row->[$max_col] =~ s/^\s+//;

        ## truncate the last column to make it fit on the screen if necessary
        if (length($row->[$max_col]) > $max_len[$max_col]) {

            if (not $opt_l) {
                $row->[$max_col] =
                    substr($row->[$max_col], 0, $max_len[$max_col] - 3) . "...";
            }
            else {
                # -long option wraps to the next line.
                $wrapped_rows = wrap(" " x $wrap_prefix_len, " " x $wrap_prefix_len, $row->[$max_col]);
                $wrapped_rows =~ s/^\s+//;
                @extra_rows = split "\n",  $wrapped_rows;
                $row->[$max_col] = shift @extra_rows;
            }
        }
        push @row_strings, sprintf($format_string, @$row), @extra_rows;
    }

    return($header_string, $divider_string, @row_strings);
}

1;
