#!/usr/intel/pkgs/perl/5.26.1/bin/perl

use strict;
use warnings;

use FindBin;

FindBin::again();
my ($systemRoot);
BEGIN {
  $systemRoot = $ENV{GK_UTILS_DIR} || $FindBin::RealBin;
  $systemRoot =~ s|/nfs/(\w+)/disks|/nfs/site/disks|;

  print "System Root = ${systemRoot}\n" unless ($ENV{QUIET_MODE});
  unshift(@INC, $systemRoot);
  unshift(@INC, "${systemRoot}/lib");
}

use File::Basename;
use File::Spec;
use Getopt::Long;
use GkUtil qw(:DEFAULT :print);

GkUtil::set_prefix(basename($0));

my %OPT =
  (
   host => $ENV{__NB_FEEDER_HOST},
   port => $ENV{__NB_FEEDER_PORT},
   taskid => $ENV{__NB_FEEDER_TASK},
  );

my $nbfeeder_base_path = "/usr/intel/common/pkgs/nbflow";
my $nbfeeder_path;

my @job_fields =
  qw(
      Name
      Status
      CmdLine
      Class
      Workstation
      Jobid
      Fullid
      UUID
      CmdName
      ExitStatus
      StartTime
      RUsage
      TimesPolicyRestarted
      TimesRestarted
      SuspendReason
   );

GetOptions(\%OPT,
           "status_file|status=s",
           "nbfeeder_version|nbflow_version=s",
           "host=s",
           "port=s",
           "taskid=s",
          );



# Handle Netbatch API
if ($OPT{nbfeeder_version}) {
  if ($OPT{nbfeeder_version} =~ m|^/|) {
    $nbfeeder_path = $OPT{nbfeeder_version};
  } else {
    $nbfeeder_path = File::Spec->catdir($nbfeeder_base_path, $OPT{nbfeeder_version});
  }
} elsif ($ENV{__NB_FEEDER_BIN_PATH}) {
  $nbfeeder_path = File::Spec->catdir($ENV{__NB_FEEDER_BIN_PATH}, "..");
} elsif ($ENV{NBFEEDER_VERSION}) {
  $nbfeeder_path = File::Spec->catdir($nbfeeder_base_path, $ENV{NBFEEDER_VERSION});
}

&fatal_error("Undefined Netbatch Feeder Path") unless ($nbfeeder_path);
&fatal_error("Netbatch Feeder Path '${nbfeeder_path}' does not exist") unless (-d $nbfeeder_path);

unshift(@INC, File::Spec->catdir($nbfeeder_path, qw(etc api perl lib)));
require NBAPI::Operations::StatusOperation;
NetbatchOperation::setCommandsPath(File::Spec->catdir($nbfeeder_path, qw(bin)));

# Create Target & Task ID
&fatal_error("Undefined Feeder Host") unless ($OPT{host});
&fatal_error("Undefined Feeder Port") unless ($OPT{port});
&fatal_error("Undefined Task ID") unless ($OPT{taskid});

my $target = join(":", $OPT{host}, $OPT{port});
my $taskid = $OPT{taskid};
$taskid =~ s/^\w+\.//;

my $operation = new StatusOperation('jobs');
$operation->setTarget($target);
$operation->setFilter("Task == '${taskid}'");
$operation->setFields(join(',', @job_fields));
$operation->setOptionForce(format => "block");
my $cmd = $operation->buildCommandLine();

$cmd .= " > $OPT{status_file}" if ($OPT{status_file});

system($cmd);

exit(0);
