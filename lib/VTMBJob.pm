#!/usr/intel/bin/perl -w
#---------------------------------------------------------------------------------------------------
#     Package Name: VTMBJob.pm
#          Project: Haswell
#            Owner: Chancellor Archie(chancellor.archie@intel.com)
#      Description: This package was developed for job creation, tracking, and submission.
#
#
#  (C) Copyright Intel Corporation, 2008
#  Licensed material -- Program property of Intel Corporation
#  All Rights Reserved
#
#  This program is the property of Intel Corporation and is furnished pursuant to a written license
#  agreement. It may not be used, reproduced, or disclosed to others except in accordance with the
#  terms and conditions of that agreement
#---------------------------------------------------------------------------------------------------

##---------------------------------------------------------------------------------------------------
## Package Info
##---------------------------------------------------------------------------------------------------
package VTMBJob;    # Package name

##---------------------------------------------------------------------------------------------------
## Required Libraries
##---------------------------------------------------------------------------------------------------
use strict;         # Use strict syntax pragma
use warnings;
use FindBin;

use VTMBObject;     # All objects derived from VTMBObject
use Data::Dumper;
use File::Basename;    # For basename()
use Time::Local;
use MIME::Lite;
#Set the PATH to NBFEEDER Commands.
NetbatchOperation::setCommandsPath(
    "/nfs/site/gen/adm/netbatch/nbfeeder/install/$ENV{'NBFEEDER_VERSION'}/bin");

# Path to NBFeeder API's
# Set the PATH to NBFEEDER API's.
use lib "/nfs/site/gen/adm/netbatch/nbfeeder/install/$ENV{'NBFEEDER_VERSION'}/etc/api/perl/lib";

# NBFeeder API Libs
use NBAPI::NetbatchOperation;
use NBAPI::Operations::StatusOperation;
use NBAPI::Operations::SubmitJobOperation;
use NBAPI::Operations::RemoveJobOperation;
use NBAPI::Operations::SuspendJobOperation;
use NBAPI::Operations::ResumeJobOperation;
use NBAPI::Operations::RecallJobOperation;
use NBAPI::Operations::StartFeederOperation;
use NBAPI::Operations::LoadTaskOperation;
use NBAPI::NetbatchOperationResponse;
use NBAPI::ResultSet;
use NBAPI::Operations::StopTaskOperation;
use NBAPI::Operations::DeleteTaskOperation;
use NBAPI::Operations::HupFeederOperation;

use NBAPI::Feeder::Task;
use NBAPI::Feeder::Conf;
use NBAPI::Feeder::Queue;
use NBAPI::Feeder::Policy;
use NBAPI::Feeder::Schedule;
use NBAPI::Feeder::JobsList;
use NBAPI::Feeder::JobsFile;
use NBAPI::Feeder::Permissions;
use NBAPI::Feeder::CustomField;
use NBAPI::Feeder::Setup;
use NBAPI::Feeder::Finalize;
use NBAPI::Feeder::OnSuccess;
use NBAPI::Feeder::OnFailure;
use NBAPI::Feeder::ConfigurationBlock;
use NBAPI::Feeder::Environment;
use NBAPI::Feeder::DelegatedTask;
use NBAPI::Feeder::PoolDelegateGroup;
use NBAPI::Feeder::UseDelegateGroups;
use NBAPI::Feeder::MachineDelegateGroup;
use NBAPI::Feeder::Machines;
use NBAPI::Feeder::FlowRoot;

#---------------------------------------------------------------------------------------------------
# Inheritance
#---------------------------------------------------------------------------------------------------
use vars qw(@ISA);
@ISA = qw(VTMBObject);
our $realbin = $FindBin::RealBin;

#---------------------------------------------------------------------------------------------------
# new()
#   Object constructor
#---------------------------------------------------------------------------------------------------
sub new {
    my $class = shift;
    my $self;


    # Initialize object properties and override with user values if specified.
    $self = {
        FEEDER_NAME         => undef,  # NBFeeder name
        NB_STATUS      => undef,    # NBFeeder Job Status
        NB_RETRIES     => 0,        # NBFeeder Task Retries
        NB_EXIT_STATUS => undef,    #NBFeeder Task Exit Status
        STATUS         => undef,    # NBFeeder Job Status
        TASK_ID        => undef,    # NBFeeder Task ID
        TASK_ORDER =>
          undef,    # GK Utils Task order will be used in gk_report.txt in the future.
        TOTAL_JOBS    => undef,    # Number of Test
        REGRESS_COUNT => undef,    # Number of Test
        PASSING       => undef,    # Number of Passing Test
        FAILING       => undef,    # Number of Passing Test
        WAITING       => undef,    # Number of Passing Test
        WAIT_LOCAL    => undef,    # Number of Local  Waiting Jobs
        WAIT_REMOTE   => undef,    # Number of Remote Waiting Jobs
        WAIT_REASON   => undef,    # Wait Reason
        RUNNING       => undef,    # Number of Running Jobs
        SKIPPED       => undef,    # Number of SKIPPED Jobs
        HAS_ENV_BLOCK => undef,    # Task has an ENV Block
        DUT           => undef,    # DU Name
        NAME          => undef,    # Job Name
        CMDS          => undef,    # Job Run Commandline
        CMD_TYPE      => undef,    # Commandline Type
        ENV_ARGS      => undef,    # ENV Arguments
        ENV_FILE      => undef,    # ENV File
        CSH_FILE      => undef,    # CSH File
        JOBS_FILE     => undef,    # JOBS File
        DEP_COND   => undef,   # Determine if Dependency condition before job is submitted
        DEPENDENCY => undef,   # DEPENDENCY name
        DEPENDENCY_FULL     => undef,  # Full Dependencies
        JOBFILE             => undef,  # Full Path to JobFile
        EMPTY_JOBFILE       => 0,
        ALLOW_EMPTY_JOBFILE => undef,
        RPT_FILE            => undef,  # Full Path to Simulation RPT File
        LOG_FILE            => undef,  # Full Path to Log File
        TASK_PATH           => undef,  # Absolute Path of Task for NBFEEDER
        TASK_NAME           => undef,  # Name of Task for NBFEEDER
        TASK_FILE           => undef,  # Task File
        FEEDER_TARGET       => undef,  # NBFeeder Target $host:$port
        FEEDER_STATUS       => undef,  # Status of Feeder
        FEEDER_HOST         => undef,  # Host to run feeder on.
        FEEDER_LOST         => 0,      # Track when Connection to Feeder has been lost
        SIM_MODE            => undef,  # Simulation Mode, 32 or 64 bit.
        BIT_MODE            => undef,  # Bit Mode, 32 or 64 bit.
        SIM_VALUE           => undef,  # Simulation Value
        NB_SUBMITTED_TIME   => undef,  # Netbatch Start Time
        NB_START_TIME       => undef,  # Netbatch Start Time
        NB_END_TIME         => undef,  # Netbatch Start Time
        WORKAREA            => undef,  # Work area for this job.
        MODEL               => undef,  # Model Root for this Task/Job
        GATING              => 1,      # This job should be gating by default.
        ERROR_DESC          => undef,  # Given an Error, this is a description
        PRE_EXEC_JOB        => undef,  # Pre Execution Job
        EARLY_KILL          => undef,  # If job should fail, kill entire process.
        EARLY_KILL_RGRS_CNT => undef,  # If count exceeded, kill the entire process
        NBCLASS             => undef,  # Netbatch Class
        NBPOOL              => undef,  # Netbatch Pool
        NBQSLOT             => undef,  # Netbatch Qslot
        NBJOB_OPTS          => undef,  # NBJOB Options
        SPAWN_JOB_TYPE      => undef,  # Job TYPE
        JOB_POST_EXEC       => undef,  # Job Post Exec
        JOB_TYPE            => undef,  # Job TYPE
        JOB_RUN_STATS       => undef,  # Job Run Stats
        JOB_EXIT_STATUS     => undef,  # Job Exit Status
        TASK_CPU_TIME       => undef,  # Task CPU Time
        WALLTIME            => 0,      # Wall Time
        FORCED_FAIL         => 0,      # Force Job to Fail, independent of Netbatch Status
        EMAIL_ON_FAIL  => 0,     # Flag to record Email has been sent to user for failure.
        AUTO_REQ       => undef, # Override Default Resubmission Arguments
        FCM_NB_N_NB    => undef, # Netbatch in Netbatch Enabled.
        ADD_CMD        => undef, # Add Task after job
        ADD_GATING     => undef, # Add Task Gating
        ADD_NAME       => undef, # Add Task NAME
        SPAWN_AUTO_REQ => undef, # Add Task NAME
        JOB_ENV        => undef, # Job Environment Settings
        DELEGATE_GROUP => undef, # Specify a Group of Delegate Machines.
        TIME_2_LIVE    => undef, # Time to live directive in NBTask file
        PRUNE_TASK     => undef, # Mark a Task for Removal
        DISABLE_NB_CHECK => undef,    # Disable the NB check.
        SMART =>
          undef
        ,   #Mark a task for removal based on SMART keyword in JobHash if depdency not met
        @_,
    };

    #Bless the reference and return it.
    bless $self, $class;
    return $self;
}
##---------------------------------------------------------------------------------------------------
## task_status()
##   Returns the Status of a Task in NBFeeder.
##---------------------------------------------------------------------------------------------------
sub task_status {

    # Get the Object Reference
    my ( $self, $objRef, $ward, $conf, $parent ) = @_;

    # Setup variables for NBFeeder Task Status
    my ( $task_name, $operation, $response, $target, $waiting );

    # Setup variables for determine Task time stats
    my ( $start_time, $end_time, $total_time );               # In seconds
    my ( $month, $day, $year, $hours, $minutes, $seconds );
    my ($feeder_lost) = 0;

    # Initialize FEEDER Status to Not Connected.
    $self->set( 'FEEDER_STATUS', undef );

    $task_name = $self->{TASK_NAME};
    $target    = $self->{FEEDER_TARGET};
    $operation = new StatusOperation("tasks");
    $operation->setFields(
"TaskID,Task,Status,TotalJobs,LocalWaitingJobs,RemoteWaitingJobs,RunningJobs,SuccessfulJobs,FailedJobs,Submitted,Started,Finished,SkippedJobs,WaitReason,JobsWaitReason"
    );
    $operation->setFilter("task=='$self->{TASK_NAME}'");
    $operation->setOption( "target", "$target" );
    $response = $operation->execute();

    # If Response returns, set attributes of jobs object.
    # Two types of jobs can be seen in his subroutine.
    # 1) A Zombie job which was submitted by a previous process.
    # 2) A Job submitted by the current process.
    if (   ( !defined $self->{NB_STATUS} )
        && ( defined $response->{output}->{parsed_lines}[0]->{TaskID} )
      )    # New Job, but could have a Zombie Alias
    {
        $self->set( 'TASK_ID', $response->{output}->{parsed_lines}[0]->{TaskID} );
    }
    elsif (defined $response->{output}->{parsed_lines}[0]->{TaskID} )    # Job submitted by Current Process
    {

#$waiting = $response->{output}->{parsed_lines}[0]->{LocalWaitingJobs} +  $response->{output}->{parsed_lines}[0]->{RemoteWaitingJobs};
#$self->set('WAITING',      $waiting);
# If the dependency is satisfied, WAIT_REASON should become JobsWaitReason
        my ( $task_wait, $jobs_wait ) = ( "", "" );
        if ( defined $response->{output}->{parsed_lines}[0]->{WaitReason} ) {
            $task_wait = $response->{output}->{parsed_lines}[0]->{WaitReason};
        }
        if ( defined $response->{output}->{parsed_lines}[0]->{JobsWaitReason} ) {
            $jobs_wait = $response->{output}->{parsed_lines}[0]->{JobsWaitReason};
        }
        my $wait_reason = $task_wait || $jobs_wait;

        $self->set( 'WAIT_LOCAL',
            $response->{output}->{parsed_lines}[0]->{LocalWaitingJobs} );
        $self->set( 'WAIT_REMOTE',
            $response->{output}->{parsed_lines}[0]->{RemoteWaitingJobs} );
        $self->set( 'WAIT_REASON', $wait_reason );

        $self->set( 'NB_STATUS', $response->{output}->{parsed_lines}[0]->{Status} );
        $self->set( 'RUNNING',   $response->{output}->{parsed_lines}[0]->{RunningJobs} );
        $self->set( 'PASSING', $response->{output}->{parsed_lines}[0]->{SuccessfulJobs} );
        $self->set( 'FAILING', $response->{output}->{parsed_lines}[0]->{FailedJobs} );
        $self->set( 'SKIPPED', $response->{output}->{parsed_lines}[0]->{SkippedJobs} );
        $self->set( 'TOTAL_JOBS', $response->{output}->{parsed_lines}[0]->{TotalJobs} );
        $self->set( 'TASK_ID', $response->{output}->{parsed_lines}[0]->{TaskID} );
        $self->set( 'FEEDER_STATUS', "Running" );

        # Upon a successful Read. Reset the Feeder Lost var.
        $self->set( 'FEEDER_LOST', $feeder_lost );
        $self->set( 'NB_SUBMITTED_TIME',
            $response->{output}->{parsed_lines}[0]->{submitted} );

        # Once a Job is finished, set the STATUS field.
        if (   ( $response->{output}->{parsed_lines}[0]->{Status} eq "Completed" )
            || ( $response->{output}->{parsed_lines}[0]->{Status} eq "Skipped" )
            || ( $response->{output}->{parsed_lines}[0]->{Status} eq "Canceled" ) )
        {

            # Setting the Status Field
            $self->set( 'STATUS', $response->{output}->{parsed_lines}[0]->{Status} );

            # Gather Job level information.
            $self->job_status($objRef);
        }

        # If this is a spawn task, lets update the log files key if there is a failure.
        if (   defined $self->{JOB_TYPE}
            && ( $self->{JOB_TYPE} eq "SPAWN" )
            && ( $response->{output}->{parsed_lines}[0]->{FailedJobs} > 0 ) )
        {

            # Populate the list of log files for spawn task.
            $self->job_status_spawn_task($objRef);
        }

        # If Job has started, capture Start Time.
        if ( defined $response->{output}->{parsed_lines}[0]->{Started} ) {
            $self->set( 'NB_START_TIME',
                $response->{output}->{parsed_lines}[0]->{Started} );
        }

        # If Job has completed, capture End Time.
        if ( defined $response->{output}->{parsed_lines}[0]->{Finished} ) {
            $self->set( 'NB_END_TIME',
                $response->{output}->{parsed_lines}[0]->{Finished} );

            # Determine the Wall Clock time for this job.
            if ( $self->{NB_START_TIME} =~ /(\d+)\/(\d+)\/(\d+)\s*(\d+):(\d+):(\d+)/ ) {
                $month   = $1;
                $day     = $2;
                $year    = $3;
                $hours   = $4;
                $minutes = $5;
                $seconds = $6;
                $start_time =
                  timegm( $seconds, $minutes, $hours, $day, $month - 1, $year )
                  ; # timegem expects months to be in range of 0 .. 11, this is why we have $month-1
            }
            if ( $self->{NB_END_TIME} =~ /(\d+)\/(\d+)\/(\d+)\s*(\d+):(\d+):(\d+)/ ) {
                $month    = $1;
                $day      = $2;
                $year     = $3;
                $hours    = $4;
                $minutes  = $5;
                $seconds  = $6;
                $end_time = timegm( $seconds, $minutes, $hours, $day, $month - 1, $year )
                  ; # timegem expects months to be in range of 0 .. 11, this is why we have $month-1
            }
            if ( $self->{NB_END_TIME} ne "" && $self->{NB_START_TIME} ne "" ) {

                # Calculate Walltime and save.
                $total_time = $end_time - $start_time;
                $self->set( 'WALLTIME', $total_time );
            }
        }
    }
    else {
        if (
            defined $self->{NB_STATUS}
          )    # Only for Jobs which have been checked by API's before.
        {
            $feeder_lost = $self->{FEEDER_LOST} + 1;
            if ( $feeder_lost % 1 == 0 ) {
                $self->set( 'FEEDER_LOST', $feeder_lost );
                $self->set( 'NB_STATUS',   "LOST NBFEEDER Connection" );
            }
        }
    }

    # Check the Response to see if Feeder is still Active.
    #if(!defined $response->{output}->{parsed_lines}[0]->{TaskID})
    # {
    #   $objRef->info("Feeder has gone down. Restarting");
    #   $self->start_feeder($objRef,$ward,$conf);
    #   $response = $operation->execute();
    # }

    # #Return the Response
    # return $response;
}
##---------------------------------------------------------------------------------------------------
## job_status()
##   Returns the Status of a Job in NBFeeder.
##---------------------------------------------------------------------------------------------------
sub job_status {

    # Get the Object Reference
    my ( $self, $objRef ) = @_;

    # Setup variables for determine Task time stats
    my ( $target, $task_id, $operation, $response );
    my ( $cputime, $cputime_set ) = ( 0, 0 );

    # Set FEEDER Target, and Task ID.
    $target  = $self->{FEEDER_TARGET};
    $task_id = $self->{TASK_ID};

    # Process Job operation
    $operation = new StatusOperation("jobs");
    $operation->setFields("name,status,JobLogFile,exitstatus,utime,stime,wtime");
    $operation->setFilter("task=='$task_id'");
    $operation->setOption( "target", "$target" );
    $response = $operation->execute();

    # Compute CPU Time
    if ( defined $response->{output}->{parsed_lines}[0]->{Utime} ) {
        foreach my $utime ( @{ $response->{output}->{parsed_lines} } ) {
            $cputime += $utime->{Utime};
            $cputime_set = 1;
        }
    }

    # Capture Job Status, update log files in case job has been rerun.
    if ( !defined $self->{REGRESS_COUNT} ) {

# Non Regression Task and distinguish between SPAWN which can have 1 or more jobs and single job task.
        if ( defined $self->{JOB_TYPE} && ( $self->{JOB_TYPE} eq "SPAWN" ) ) {

            # Handle SPAWN Task
            $objRef->info("JOB_STATUS for : SPAWN Task file $self->{TASK_FILE}");
        }
        else {

            # Get CPU Time
            # Handle Single Job/Non SPAWN Task.
            $objRef->info("JOB_STATUS for : Single Job Task file $self->{TASK_FILE}");
            $self->set( 'JOB_EXIT_STATUS',
                $response->{output}->{parsed_lines}[0]->{ExitStatus} );

            # Determine if the logfile is different because job might have been rerun.
            if (
                defined $self->{LOG_FILE}
                && ( $self->{LOG_FILE} ne
                    $response->{output}->{parsed_lines}[0]->{JobLogFile} )
              )
            {
                $objRef->info("job_status : Updating job file for $self->{TASK_FILE}");
                $self->set( 'LOG_FILE',
                    $response->{output}->{parsed_lines}[0]->{JobLogFile} );
            }
        }

        # Get the CPUTime if its set.
        $self->set( 'TASK_CPU_TIME', $cputime ) if ( $cputime_set == 1 );
    }
    else {

        # Handle Regression Task.
        $objRef->info("JOB_STATUS for : Regression Task file $self->{TASK_FILE}");
        $self->set( 'TASK_CPU_TIME', $cputime ) if ( $cputime_set == 1 );
    }

}
##---------------------------------------------------------------------------------------------------
## job_status_spawn_task()
##   Returns the Status of a Job witin Spawn Task in NBFeeder.
##---------------------------------------------------------------------------------------------------
sub job_status_spawn_task {

    # Get the Object Reference
    my ( $self, $objRef ) = @_;

    # Setup variables for determine Task time stats
    my ( $target, $task_id, $operation, $response );
    my ( $cputime, $cputime_set ) = ( 0, 0 );
    my $logfiles;

    # Set FEEDER Target, and Task ID.
    $target  = $self->{FEEDER_TARGET};
    $task_id = $self->{TASK_ID};

    # Process Job operation
    $operation = new StatusOperation("jobs");
    $operation->setFields("name,status,JobLogFile,exitstatus");
    $operation->setFilter("basetask($task_id)");
    $operation->setOption( "target", "$target" );
    $response = $operation->execute();

    # Loop thru the Response and get the log files that are failing.
    my @temp_log;
    foreach my $spawn_task_status ( @{ $response->{output}->{parsed_lines} } ) {
        if (   ( defined $spawn_task_status->{ExitStatus} )
            && ( $spawn_task_status->{ExitStatus} != 0 )
            && ( defined $spawn_task_status->{JobLogFile} )
            && -e $spawn_task_status->{JobLogFile} )
        {
            $logfiles .= " $spawn_task_status->{JobLogFile}";
        }
    }

    # If we find a logfile, set in self and send back.
    if ( defined $logfiles ) {
        $self->set( 'LOG_FILE', $logfiles );
    }
}

##---------------------------------------------------------------------------------------------------
## nbfeeder_list()
##   Returns the List of Existing NBFeeders on a machine
##---------------------------------------------------------------------------------------------------
sub nbfeeder_list {

    # Get the Object Reference
    my ($self) = @_;

    # Setup variables for NBFeeder Task Status
    my ( $operation, $response );

    $operation = new StatusOperation("feeders");
    $operation->setFields("Status,Host,Port,LastUpdate");
    $operation->setFilter("user=='$ENV{USER}'");
    $response = $operation->execute();

    #Return the Response
    return $response;
}
##---------------------------------------------------------------------------------------------------
## submit_tasks()
##   Submit a Task to NBFeeder
##---------------------------------------------------------------------------------------------------
sub submit_tasks {

    # Get the Object Reference
    my ( $self, $objRef, $feeder_ward, $feeder_config ) = @_;

    # Export Task name for Procmon
    $ENV{'__NB_TASK_NAME'} = $self->{TASK_NAME};
    $ENV{'__NB_TASK_NAME'} =~ s/\.\d+\.([^.]+)$/.$ENV{'GK_STEP'}.$1/;

    if ( !-e $self->{TASK_FILE} ) {
        $objRef->error("Task file $self->{TASK_FILE} has not been generated");
        $objRef->check_errors();
        return;
    }

    # Setup variables for NBFeeder Task Submission
    my ( $operation, $response, $lines );
    $operation = new StartFeederOperation();
    $operation->setBinaryOption("join");
    $operation->setOption( "task",      "$self->{TASK_FILE}" );
    $operation->setOption( "work-area", "$feeder_ward" );
    $operation->setOption( "conf",      "$feeder_config" );
    $response = $operation->execute();

    #Check Status of Submission
    if ( !$response->exitStatus()->isZero() ) {
        $objRef->error("NBFeeder didn't accept task:$self->{TASK_NAME}");
        foreach $lines ( @{ $response->{output}->{lines} } ) {
            chomp($lines);
            $objRef->error("NBAPI ERROR: $lines");
        }

# Task was not accepted by NBFeeder, set the Fields so other subroutines will work properly.
#$self->set('NB_STATUS',"NOT ACCEPTED BY NBFEEDER");
        $self->set( 'PASSING',       "" );
        $self->set( 'FAILING',       "" );
        $self->set( 'NB_START_TIME', "" );
        $self->set( 'NB_END_TIME',   "" );
        $self->set( 'TOTAL_JOBS',    "" );
    }
    else {
        $objRef->info("Submitted Task:$self->{TASK_NAME}");
        $self->set( 'FEEDER_TARGET',
            "$ENV{'HOST'}:$response->{output}->{parsed_lines}[0]->{port}" );
        $self->set( 'TASK_ID',   "$response->{output}->{parsed_lines}[0]->{task_id}" );
        $self->set( 'NB_STATUS', "Submitted" );

        # Initial Regression Results
        $self->set( 'PASSING',       "" );
        $self->set( 'FAILING',       "" );
        $self->set( 'NB_START_TIME', "" );
        $self->set( 'NB_END_TIME',   "" );
        $self->set( 'TOTAL_JOBS',   "" );

        # If regression list, set number of test as REGRESS_COUNT, otherwise set to 1.
        if ( defined $self->{REGRESS_COUNT} ) {
            $self->set( 'WAITING', $self->{REGRESS_COUNT} );
        }
        else {
            $self->set( 'WAITING', 1 );
        }
    }

    # # Terminate on errors
    # $objRef->check_errors();
}
##---------------------------------------------------------------------------------------------------
## submit_parent_task()
##   Submit a Parent Task to NBFeeder, Start the Feeder if its down,  and update all subtasks
##---------------------------------------------------------------------------------------------------
sub submit_parent_task {

    # Get the Object Reference
    my ( $self, $objRef, $feeder_ward, $feeder_config, $objSubTask,$feeder_instance,$feeder_max ) = @_;
    my $exit_code;

    # Export Task name for Procmon
    $ENV{'__NB_TASK_NAME'} = $self->{TASK_NAME};
    $ENV{'__NB_TASK_NAME'} =~ s/\.\d+\.([^.]+)$/.$ENV{'GK_STEP'}.$1/;

    if ( !-e $self->{TASK_FILE} ) {
        $objRef->error("Task file $self->{TASK_FILE} has not been generated");
        $objRef->check_errors();
        return;
    }

    my ( $operation, $response, $lines, $output );
    my $loop_cnt = 0;

    # Setup variables for NBFeeder Task Submission
    do {
        $operation = new LoadTaskOperation( $self->{TASK_FILE} );
        $operation->setTarget( $self->{FEEDER_TARGET} );
        $operation->setOption( "timeout", "600" );
        $response  = $operation->execute();
        $exit_code = $response->exitStatus()->getValue();

        # Check for Errors.
        if ( !$response->exitStatus()->isZero() ) {
            foreach $lines ( @{ $response->{output}->{lines} } ) {
                chomp($lines);
                $objRef->info("NBAPI ERROR: $lines");
            }

            my $loopcnt = $loop_cnt + 1;
            $objRef->info(
                "Could not contact feeder, trying to restart nbfeeder, retry $loopcnt");
            sleep( 300 * $loop_cnt );
            $self->start_feeder( $objRef, $feeder_ward, $feeder_config, $feeder_instance, $feeder_max );
        }
        else {

            # Check for Warnings
            foreach $lines ( @{ $response->{output}->{lines} } ) {
                chomp($lines);
                $objRef->set( 'QUIET', 1 ) if !$ENV{'DISABLE_QUIET_MODE'};
                if ( $lines =~ /WARN:/ ) {
                    $objRef->warning("NBAPI WARNING: $lines");
                }
                $objRef->set( 'QUIET', 0 ) if !$ENV{'DISABLE_QUIET_MODE'};
            }
        }
    } while ( !$response->exitStatus()->isZero() && $loop_cnt++ < 5 );

    #Check Status of Submission
    if ( !$response->exitStatus()->isZero() ) {
        $objRef->error("NBFeeder didn't accept task:$self->{TASK_NAME}");
        foreach $lines ( @{ $response->{output}->{lines} } ) {
            chomp($lines);
            $objRef->error("NBAPI ERROR: $lines");
        }

        #$self->set('NB_STATUS',"NOT ACCEPTED BY NBFEEDER");
        $self->set( 'PASSING',       "" );
        $self->set( 'FAILING',       "" );
        $self->set( 'NB_START_TIME', "" );
        $self->set( 'NB_END_TIME',   "" );
    }
    else {

#This is a Parent Task, to enable status checking of all subtasks.
# We need to gather all Task ID's and update the respective entry in the job hash.
# This is done thru an extension of the API provided by Noam Ambar which is less costly than
# simply checking the status directly by FEEDER queries.
        my $task_ids;
        my %task_2_ids;
        $response->outputSet()->first();
        do {
            my $alltask_ids = $response->outputSet()->getParsedLine();
            foreach $task_ids ( keys %$alltask_ids ) {
                $task_2_ids{ $$alltask_ids{$task_ids} } = $task_ids;
            }
        } while ( $response->outputSet()->next() );

        #      foreach my $subu (@$objSubTask)
        #        {
        #           print Data::Dumper->Dump( [$subu], ["VTMBJobs"] );
        #
        #        }
        #

        #     # This is a parent Task, we need to gather Task ID from all Sub Tasks.
        #     # Loop thru the Task Names and find the Task ID's.
        # If a task does not have an existing TASK ID, then update it, otherwise skip.
        my $subtask;
        foreach $subtask (@$objSubTask) {

            # Set Fields if this is a newly added task that does not have a TASK ID.
            # This is used for SPAWN TASK
            if ( !defined $subtask->{TASK_ID} ) {
                $subtask->set( 'TASK_ID',       $task_2_ids{ $subtask->{TASK_NAME} } );
                $subtask->set( 'FEEDER_TARGET', "$self->{FEEDER_TARGET}" );

                # Because this is a nested task, cheaply get Task ID's by checking status.
                $subtask->task_status( $objRef, $feeder_ward, $feeder_config, 1 );
                $objRef->info(
                    "Submitted Task:$subtask->{TASK_NAME}, TaskID:$subtask->{TASK_ID}");

                # Set the Stats fields for the Task.
                $subtask->set( 'NB_STATUS',     "Submitted" );
                $subtask->set( 'PASSING',       "" );
                $subtask->set( 'FAILING',       "" );
                $subtask->set( 'NB_START_TIME', "" );
                $subtask->set( 'NB_END_TIME',   "" );

            # If regression list, set number of test as REGRESS_COUNT, otherwise set to 1.
                if ( defined $subtask->{REGRESS_COUNT} ) {

                    #$subtask->set('WAITING',$subtask->{REGRESS_COUNT});
                    $subtask->set( 'WAIT_LOCAL', $subtask->{REGRESS_COUNT} );
                }
                else {

                    #$subtask->set('WAITING',1);
                    $subtask->set( 'WAIT_LOCAL', 1 );
                }

            }
        }

# Old Code
#  $objRef->info("Submitted Task:$self->{TASK_NAME}");
#  $self->set('FEEDER_TARGET',"$ENV{'HOST'}:$response->{output}->{parsed_lines}[0]->{port}");
#  $self->set('TASK_ID',"$response->{output}->{parsed_lines}[0]->{task_id}");
#  $self->set('NB_STATUS',"Submitted");

        # Initial Regression Results
        #  $self->set('PASSING',"");
        #  $self->set('FAILING',"");
        #  $self->set('NB_START_TIME',"");
        #  $self->set('NB_END_TIME',"");

        #  # If regression list, set number of test as REGRESS_COUNT, otherwise set to 1.
        #  if(defined $self->{REGRESS_COUNT})
        #   {
        #     $self->set('WAITING',$self->{REGRESS_COUNT});
        #   }
        #  else
        #   {
        #     $self->set('WAITING',1);
        #   }
    }

    # Terminate on errors
    $objRef->check_errors();
}
###---------------------------------------------------------------------------------------------------
### create_config_file()
###   Create NBfeeder Configuration File
###---------------------------------------------------------------------------------------------------
sub create_config_file {

    # Get the Object Reference
    my ( $self, $feeder_ward ) = @_;

    my $conf;           # Configuration File
    my $policy;         # Policy
    my $schedule;       # Schedule
    my $permissions;    # Permissions
    my @admin_users;
    my $admin;
    #my $conf_file = "$feeder_ward/.nbfeeder.$self->{'FEEDER_HOST'}.rc";
    #my $conf_file = "$realbin/.nbfeeder.gk.rc";
    my $conf_file = "$ENV{DATOOLS}/pkgs/nbconf/1.0/nbflm_feeder.conf";
    if ( -e $conf_file)
    {
        return $conf_file;
    }
    $conf = Conf->new();
    $conf->addComment("This configuration file generated gk-utils");
    $conf->globalMaxJobsLimit("20000");
    $conf->globalMaxWaitingLimit("10000");

    my $PROJECT     = $ENV{PROJECT};
    my $SUB_PROJECT = $ENV{SUB_PROJECT};
    $conf->{DIRECTIVES}{"Predictionentity"} = "GK_${PROJECT}_${SUB_PROJECT}_VPG";
    my $predictionBlock = ConfigurationBlock->new();
    $predictionBlock->initialize( "Prediction", "" );

    #$predictionBlock->name("Prediction");
    $predictionBlock->{DIRECTIVES}{"Predicted"} = "rfrt";
    $predictionBlock->{DIRECTIVES}{"System"}    = "enable";
    $conf->add($predictionBlock);

    ### Task Retention Policy.
    ### Base on Settin, completed Tasks will be clearred.
    $policy = Policy->new("TaskRetention");
    $policy->addComment("Task aging policy");

    # Schedule of how often Policy wakes up. Once a day.
    $schedule = Schedule->new();
    $policy->add($schedule);
    $schedule->recurrence("1d");

    #Delete any Task 1 days old or older
    $schedule->addAction( "DeleteOldTasks", "age=1d" );
    $conf->add($policy);

    # Permissions for Pool Administrator
    #my @admin_users = ( $ENV{GK_FEEDER_ADMIN_USER} ); Commenting this line because dont want to use this config value. Using GkConfig{admin} for now.
    if ( exists $main::GkConfig{admin} ) {
      push( @admin_users, @{ $main::GkConfig{admin} } );
    }

    if ( exists $main::GkConfig{powerusers_file} && -f $main::GkConfig{powerusers_file} )
    {
        if ( open( POWER, "< $main::GkConfig{powerusers_file}" ) ) {
            chomp( my @power_users = <POWER> );
            close(POWER);
            #push( @admin_users, @power_users );       Commenting this line because dont want power users to be Feeder admins
        }
    }

    my %feeder_admins;
    $feeder_admins{$_}++ foreach (@admin_users);

    $permissions = Permissions->new();
    $permissions->addComment("Adding GK Admins as admin for this feeder");
    foreach $admin (@admin_users) {
    $permissions->addUser("$admin");
    }
    $permissions->addOperation("PoolAdmin");
    $conf->add($permissions);

    # Adding my own Field Definition using the Configuration Block Object.
    my $cb = ConfigurationBlock->new();
    $cb->initialize( "FieldSize", "" );
    $cb->{DIRECTIVES}{"Jobs"} = "Name:1000 result_file_name:1000";
    $conf->add($cb);

    # Write the Configuration File
    $conf->write($conf_file);
    return $conf_file;
}

###---------------------------------------------------------------------------------------------------
### create_cshfile()
###   Create CSH File
###---------------------------------------------------------------------------------------------------
sub create_cshfile {

    # Get the Object Reference
    my ( $self, $objRef ) = @_;
    my $csh_file = "$self->{MODEL}/GATEKEEPER/NBFeederTaskJobs/$self->{NAME}.csh";

    # Open ENV File and put into CSH file.
    open( ENV_FILE, "$self->{ENV_FILE}" );
    open( CSH_FILE, ">$csh_file" );
    while (<ENV_FILE>) {
        print CSH_FILE $_;
    }
    print CSH_FILE "$self->{CMDS}\n";
    close(ENV_FILE);
    close(CSH_FILE);

    # Ensure the file is executable by owner.
    system("chmod 750 $csh_file");

    # Update Object with CSH_FILE
    $self->set( 'CSH_FILE', $csh_file );
}

###---------------------------------------------------------------------------------------------------
### create_acereg_taskfile()
###   Invoke acereg, grab the jobfile, and create a taskfile.
###---------------------------------------------------------------------------------------------------
sub create_acereg_taskfile {

    # Get the Object Reference
    my ( $self, $objRef, $toolRef ) = @_;
    my $task;                  # Task
    my $queue;                 # Queue
    my $jobsfile;              # JobFile
    my $dep;                   # Dependency
    my $env;                   # Environment
    my $task_name;             # Task Name
    my $task_file;             # Task File
    my $log_file;              # Log  File
    my $dep_index;             # Dependency Index
    my $setup;                 # Setup
    my $use_delg_group;        # Use Delegate Groups
    my $machine_delg_group;    # Machine Delegate Group
    my $machines;              # Machines to assigned to Machine Delegate Group.
    my $nbjob_string;          # NBJob String
    my @temp;
    my ( $cmd, @cmd_results, $csh_file );
    my $job_count = 0;
    $toolRef->info("  Invoking acereg for $self->{NAME}");

    # Create acereg cmd file.
    $csh_file = "$self->{CSH_FILE}";
    $csh_file =~ s/\.csh/\.acereg\.csh/;
    open( ACEREG_CSH_FILE, ">$csh_file" );
    print ACEREG_CSH_FILE "#!/bin/csh -f\n";
    print ACEREG_CSH_FILE "$self->{CSH_FILE}\n";
    print ACEREG_CSH_FILE "$self->{CMDS}\n";
    close(ACEREG_CSH_FILE);
    system("chmod u+x $csh_file");

    #$cmd ="source $self->{CSH_FILE};$self->{CMDS}";
    $cmd = $csh_file;

    # Invoke and grab acereg jobsfile.
    if ( $toolRef->run( $cmd, \@cmd_results ) != 0 ) {
        foreach my $acereg_line (@cmd_results) {

            # Get Jobs file and exit loop
            if ( $acereg_line =~ /Creating NBFM Jobs File\s*\'(\S+)\'\s*\n/ ) {
                $self->set( 'JOBS_FILE', $1 );
                $toolRef->info("   acereg command passed for $self->{NAME}");
                last;
            }
        }

        # Determine if the Jobfile is empty.
        if ( defined $self->{JOBS_FILE} ) {
            $cmd = "wc -l $self->{JOBS_FILE}";
            if ( $toolRef->run( $cmd, \@cmd_results ) == 0 ) {
                $toolRef->debug("Job File Found:$self->{JOBS_FILE}");
                $job_count = $cmd_results[-1];
                $job_count =~ s/\s.*$//;
                chomp($job_count);
                $toolRef->info(
                    "    Jobs file for $self->{NAME} contains $job_count jobs");
            }
            if ( $job_count == 0 ) {
                $self->set( 'EMPTY_JOBFILE', 1 );
            }
        }
        else {
            $toolRef->error(
                "acereg command failed to create jobfile for : $self->{NAME}");
            $toolRef->check_errors();
        }
    }
    else {
        $toolRef->error("acereg command failed: $self->{NAME}");
        $toolRef->check_errors();
    }

    # Create Task file using jobs file above.
    $task_name = "$objRef->{TASK_PREFIX}.$self->{NAME}";
    $task_file = "$self->{MODEL}/GATEKEEPER/NBFeederTaskJobs/$self->{NAME}.nbtask";

    #   $log_file     = "$self->{MODEL}/GATEKEEPER/NBLOG:$self->{NAME}";

    #   # Not Really needed for Build task, but is consistent with settings in Regressions
    #   $nb_task_name = $task_name;
    #   $nb_task_name =~ s/\.\d+\.([^.]+)$/.$ENV{'GK_STEP'}.$1/;

    # Create new Task
    $task = Task->new($task_name);

# Setup Task Submission Args
# Use Default submission arguments unless overriden.
# Commented out
#   if(!defined $self->{AUTO_REQ})
#    {
#      $task->submissionArgs("--incremental-log --class \"$self->{NBCLASS}\" --autoreq attempts=3:(exit<0)&&((exit!=-8)&&(exit!=-7)&&(exit!=-3107)) ");
#    }
#   else
#    {
#      $task->submissionArgs("--incremental-log --class \"$self->{NBCLASS}\" --$self->{AUTO_REQ} ");
#    }
# Taken directly from APD
    my $class_reservation_string = "";
    my $netbatch_priority_string = "--priority 10";

    $task->submissionArgs(
"--class $self->{'NBCLASS'} ${class_reservation_string} ${netbatch_priority_string} --on-job-finish \'((ExitStatus==-310)||(ExitStatus==-66)):Requeue(10),((ExitStatus==2)||(ExitStatus==3)||(ExitStatus==4)||(ExitStatus==88)||(ExitStatus==10)||(ExitStatus==13)||(ExitStatus==17)||(ExitStatus==18)||(ExitStatus==-3002)||(ExitStatus==1)):Requeue(1),(ExitStatus<0 && ExitStatus!=-8):Requeue(1)\' "
    );

    # Added Queue Block
    # It contains NB Pool & Qslot information
    # It also contains max jobs, max waiting, and update Frequency
    $queue = Queue->new( $self->{NBPOOL} );
    $queue->qslot( $self->{NBQSLOT} );

    #    $queue->updateFrequency(150);

    #   $queue->maxWaiting(10);
    #   $queue->maxJobs(1000);

    # Add the queue information to the task
    $task->add($queue);

    # Setup Task Update Frequency to NBFeeder, work area.
    $task->workArea("$self->{MODEL}/GATEKEEPER");

    # $task->reportUpdateFrequency(60);

    # Add Environment Block
    $env = Environment->new();
    if ( defined $self->{JOB_ENV}->[0] ) {
        my ( $env_inc, @env_settings );
        foreach $env_inc ( @{ $self->{JOB_ENV} } ) {
            @env_settings = split( /:/, $env_inc );
            if ( $env_settings[0] eq "set" ) {
                $env->setenv( $env_settings[1], $env_settings[2] );
            }
            elsif ( $env_settings[0] eq "unset" ) {
                $env->unsetenv( $env_settings[1] );
            }
            else {
            }
        }
    }

    # else
    #  {
    #    # If nothing is defined at least add PROCMON required settings.
    #    $env->setenv("__NB_TASK_NAME",$__NB_TASK_NAME);
    #    $self->set('$self->{JOB_ENV}->[0]',"set:$__NB_TASK_NAME");
    #  }

    # If job has a CSH_FILE, add that as ENV
    if ( defined $self->{CSH_FILE} ) {
        $self->set( 'HAS_ENV_BLOCK', 1 );
        $env->setenv( "SOURCE_ENV", $self->{ENV_FILE} );
    }

    # Add ENV settings
    $task->add($env);

    #if(defined $self->{ENV_ARGS})
    # {
    #   foreach (@{$self->{ENV_ARGS}})
    #    {
    #      my($cm,$var,$val) = split(/\s+/,$_);
    #      my $env_string = $_;
    #      chomp($env_string);
    #      if($cm =~ /^unsetenv\s+/)
    #       {
    #         $env_string =~ s/$cm//;
    #         $env_string =~ s/$var//;
    #         $env->unsetenv($var,$env_string);
    #       }
    #      elsif($cm =~ /^setenv/)
    #       {
    #         $env_string =~ s/$cm//;
    #         $env_string =~ s/$var//;
    #         $env->setenv($var,$env_string);
    #       }
    #      elsif($cm =~ /^source/)
    #       {
    #         $env_string =~ s/$cm//;
    #         $env_string =~ s/$var//;
    #         $env->setenv("SOURCE_ENV",$env_string);
    #       }
    #      my $few;
    #    }
    #   $task->add($env);
    # }

    # Add the JobsFile to the Task file
    $task->jobsFile( $self->{JOBS_FILE} );

    # Add Dependencies if they exist
    if ( defined $self->{DEPENDENCY} ) {
        for ( $dep_index = 0 ; $dep_index < @{ $self->{DEPENDENCY} } ; $dep_index++ ) {
            if ( $self->{DEP_COND}->[$dep_index] eq "Success" ) {
                $task->addDependency( $self->{DEPENDENCY}->[$dep_index],
                    Task::ON_SUCCESS );
            }
            elsif ( $self->{DEP_COND}->[$dep_index] eq "Fail" ) {
                $task->addDependency( $self->{DEPENDENCY}->[$dep_index], Task::ON_FAIL );
            }
            elsif ( $self->{DEP_COND}->[$dep_index] eq "Complete" ) {
                $task->addDependency( $self->{DEPENDENCY}->[$dep_index],
                    Task::ON_COMPLETE );
            }
            elsif ( $self->{DEP_COND}->[$dep_index] eq "Finish" ) {
                $task->addDependency( $self->{DEPENDENCY}->[$dep_index],
                    "OnFinish < 1000" );
            }
            else {
                $task->addDependency( $self->{DEPENDENCY}->[$dep_index],
                    $self->{DEP_COND}->[$dep_index] );
            }
        }
    }

    ### Add the Task Name and Task File to Jobs Object
    $self->set( 'TASK_FILE', $task_file );
    $self->set( 'TASK_NAME', $task_name );

    #$self->set('LOG_FILE', $log_file);

    # Write The Task File
    $task->write("$task_file");

}
###---------------------------------------------------------------------------------------------------
### create_taskfile()
###   Create NBFeeder Task or Delegated Task File
###---------------------------------------------------------------------------------------------------
sub create_taskfile {

    # Get the Object Reference
    my ( $self, $objRef, $build_to ) = @_;

    my $task;                  # Task
    my $queue;                 # Queue
    my $jobs;                  # Job
    my $dep;                   # Dependency
    my $env;                   # Environment
    my $task_name;             # Task Name
    my $task_file;             # Task File
    my $task_path;             # Task File
    my $log_file;              # Log  File
    my $dep_index;             # Dependency Index
    my $setup;                 # Setup
    my $use_delg_group;        # Use Delegate Groups
    my $machine_delg_group;    # Machine Delegate Group
    my $machines;              # Machines to assigned to Machine Delegate Group.
    my $nbjob_string;          # NBJob String
    my @temp;
    my $nb_task_name;

    # Create Task Name, Task File, & Log File Name
    $task_name = "$objRef->{TASK_PREFIX}.$self->{NAME}";

    #$task_name = "$self->{NAME}";
    $task_file = "$self->{MODEL}/GATEKEEPER/NBFeederTaskJobs/$self->{NAME}.nbtask";
    $log_file  = "$self->{MODEL}/GATEKEEPER/NBLOG:$self->{NAME}";

    $task_path = "$objRef->{TASK_PREFIX}/$task_name";
    $task_path = "/${task_path}" if ( $task_path !~ m|^/| );

    # Not Really needed for Build task, but is consistent with settings in Regressions
    $nb_task_name = $task_name;
    $nb_task_name =~ s/\.\d+\.([^.]+)$/.$ENV{'GK_STEP'}.$1/;

    my $default_autoreq =
      (     "on-job-finish"
          . " '(ExitStatus>0&&ExitStatus!=1&&ExitStatus!=4&&ExitStatus!=107&&ExitStatus!=404&&ExitStatus!=110&&ExitStatus!=111&&ExitStatus!=218):Requeue(2), ExitStatus<0&&ExitStatus>-7:Requeue(3), ExitStatus<-15&&ExitStatus!=-19&&ExitStatus!=-305&&ExitStatus!=-3017&&ExitStatus!=-3023&&ExitStatus!=-1220:Requeue(5), ExitStatus==404:Exclude(15m):Requeue(3), ExitStatus==218:Exclude(15m):Requeue(3), ExitStatus==110:Exclude(15m):Requeue(3), ExitStatus==12:Exclude(15m):Requeue(3), ExitStatus==111:Exclude(15m):Requeue(3)'"
      );
    if ( defined $main::cfg_common{default_autoreq} ) {
       $default_autoreq = $main::cfg_common{default_autoreq};
    }

    my $submission_args = "--incremental-log --class \"$self->{NBCLASS}\" --${default_autoreq} ";

    if ( !defined $self->{DELEGATE_GROUP} )    # Create a Task File
    {

        # Create new Task
        $task = Task->new($task_name);

        # Setup Task Submission Args
        # Use Default submission arguments unless overriden.
        if ( defined $self->{AUTO_REQ} ) {
            $submission_args = "--incremental-log --class \"$self->{NBCLASS}\" --$self->{AUTO_REQ} ";
        }

        # Added Queue Block
        # It contains NB Pool & Qslot information
        # It also contains max jobs, max waiting, and update Frequency
        $queue = Queue->new( $self->{NBPOOL} );
        $queue->qslot( $self->{NBQSLOT} );

        # $queue->updateFrequency(150);
        $queue->maxWaiting(10);
        $queue->maxJobs(2000);

        # Add the queue information to the task
        $task->add($queue);
    }
    else {

        # Create a DelegatedTask to support task assigned to a group of machines.
        $task = DelegatedTask->new($task_name);
        $submission_args = "--incremental-log --autoreq attempts=3:(exit<0)&&((exit!=-8)&&(exit!=-7)&&(exit!=-3107)) ";


        # Setup Task Submission Args
        # Use Default submission arguments unless overriden.
        if ( defined $self->{AUTO_REQ} ) {
            $submission_args = "--incremental-log  --$self->{AUTO_REQ} ";
        }

        #Setup UseDelegateGroups
        $use_delg_group = UseDelegateGroups->new();
        $use_delg_group->addGroup("Delegate_Group");
        $task->add($use_delg_group);

        #Machine Delegate Groups
        $machine_delg_group = MachineDelegateGroup->new("Delegate_Group");

        # Add Machines
        $machines = Machines->new();
        @temp = split( / /, $self->{DELEGATE_GROUP} );
        foreach my $machine (@temp) {
            $machines->addMachine("$machine");
        }
        $machine_delg_group->add($machines);
        $task->add($machine_delg_group);
    }

    # Setup Task Update Frequency to NBFeeder, work area.
    $task->workArea("$self->{MODEL}/GATEKEEPER");
    $task->reportUpdateFrequency(60);

    # Add Environment Block
    if ( defined $self->{JOB_ENV}->[0] ) {
        $env = Environment->new();
        my ( $env_inc, @env_settings );
        foreach $env_inc ( @{ $self->{JOB_ENV} } ) {
            @env_settings = split( /:/, $env_inc );
            if ( $env_settings[0] eq "set" ) {
                $env->setenv( $env_settings[1], $env_settings[2] );
            }
            elsif ( $env_settings[0] eq "unset" ) {
                $env->unsetenv( $env_settings[1] );
            }
            else {
            }
        }

        $task->add($env);
    }

    # Add the Jobs to the Task file
    $jobs = JobsList->new();
    $jobs->addComment( $self->{DESC} );

# New Code to handle nbjob options
# This code was rewritten because there could be more than 1 nbjob option that needs to be passed.
    $nbjob_string = "nbjob run ";
    if ( defined $self->{NBJOB_OPTS} ) {
        $nbjob_string .= "$self->{NBJOB_OPTS} ";
    }

    # Check if JOB_PRE_EXEC defined.
    if ( defined $self->{JOB_PRE_EXEC} ) {
        $nbjob_string .=
          "--pre-exec '$self->{JOB_PRE_EXEC} $ENV{'MODEL'}/GATEKEEPER/pre-exec' ";
    }

    # Check if JOB_POST_EXEC defined.
    # Entry should contain --post-exec <> --log-file-dir-post-exec <>
    if ( defined $self->{JOB_POST_EXEC} ) {

        my $post_exec = $self->{JOB_POST_EXEC};
        if ($post_exec =~ /^\-\-post/) {
            $submission_args .= $post_exec;
        }else {
            $submission_args .= "--post-exec $post_exec";
        }
    }

    $task->submissionArgs($submission_args);

    #Include timeout logic
    $nbjob_string .= " --job-constraints \"wtime>$build_to:kill(-1220)\" ";

    # Include Job and logfile at the end
    # The NBjob will either be the command directly or a csh_file if defined.
    if ( !defined $self->{CSH_FILE} ) {
        $nbjob_string .= "--log-file $log_file $self->{CMDS} ";
    }
    else {
        $nbjob_string .= "--log-file $log_file $self->{CSH_FILE} ";
    }

    # Add the job string.
    $jobs->addJob($nbjob_string);
    $task->add($jobs);

    # Add Dependencies if they exist
    if ( defined $self->{DEPENDENCY} ) {
        for ( $dep_index = 0 ; $dep_index < @{ $self->{DEPENDENCY} } ; $dep_index++ ) {
            if ( $self->{DEP_COND}->[$dep_index] eq "Success" ) {
                $task->addDependency( $self->{DEPENDENCY}->[$dep_index],
                    Task::ON_SUCCESS );
            }
            elsif ( $self->{DEP_COND}->[$dep_index] eq "Fail" ) {
                $task->addDependency( $self->{DEPENDENCY}->[$dep_index], Task::ON_FAIL );
            }
            elsif ( $self->{DEP_COND}->[$dep_index] eq "Complete" ) {
                $task->addDependency( $self->{DEPENDENCY}->[$dep_index],
                    Task::ON_COMPLETE );
            }
            elsif ( $self->{DEP_COND}->[$dep_index] eq "Finish" ) {
                $task->addDependency( $self->{DEPENDENCY}->[$dep_index],
                    "OnFinish < 1000" );
            }
            else {
                $task->addDependency( $self->{DEPENDENCY}->[$dep_index],
                    $self->{DEP_COND}->[$dep_index] );
            }
        }
    }

    ### Add the Task Name and Task File to Jobs Object
    $self->set( 'TASK_FILE', $task_file );
    $self->set( 'TASK_NAME', $task_name );
    $self->set( 'LOG_FILE',  $log_file );
    $self->set( 'TASK_PATH', $task_path );

    # Write The Task File
    $task->write("$task_file");
}

###---------------------------------------------------------------------------------------------------
### create_parent_taskfile()
###   Create Nested Parent NBfeeder Task File
###---------------------------------------------------------------------------------------------------
sub create_parent_taskfile {

    # Get the Object Reference
    my ( $self, $objRef ) = @_;

    my $task;         # Task
    my $task_file;    # Task File Name
    my $task_name;    # Task Name
    my $permissions;  # Permissions
    my @admin_users;
    my @power_users;
    my $admin;
    my $power;

    # Create Task Name, Task File, & Log File Name
    $task_name = "$self->{TASK_NAME}";
    $task_file = "$self->{TASK_FILE}";

    # Create new Task
    $task = Task->new($task_name);

    # Create WORK Area setting for Parent Task.
    $task->workArea("$self->{MODEL}/GATEKEEPER");

    # Add Time 2 Live directive if Defined
    $task->ttl( $self->{TIME_2_LIVE} ) if defined $self->{TIME_2_LIVE};

# Unfortunately. There is no API which supports nested tasks by referencing an existing task.
# Put a place holder, then replace it later.
    $task->addComment("REPLACE_WITH_SUB_TASK");

    my $project = $ENV{PROJECT};
    my $event = $ENV{GK_EVENTTYPE};
    my $cluster = $ENV{GK_CLUSTER};
    my $turninid = $ENV{GK_TURNIN_ID};
    if (!$turninid) {
        $turninid = 0;
    }
    my $flow =FlowRoot->new();
    $flow->name("$task_name");
    $flow->tags("${project} ${project}_${event} ${project}_${cluster} ${project}_${event}_${cluster}");
    $task->add($flow);
    $task->submissionArgs("--properties \"gk_turnin_id=$turninid,projectname=$project\"");

    if ( exists $main::GkConfig{admin} ) {
      push( @admin_users, @{ $main::GkConfig{admin} } );
    }

    if ( $ENV{'GK_EVENTTYPE'} eq "filter" ) {
        if ( exists $main::GkConfig{powerusers_file}
            && -f $main::GkConfig{powerusers_file} )
        {
            if ( open( POWER, "< $main::GkConfig{powerusers_file}" ) ) {
                chomp( @power_users = <POWER> );
                close(POWER);
                push( @power_users, @admin_users );
            }
        }

        $permissions = Permissions->new();
        $permissions->addComment("Adding Power Users and Admin users as admin for this Filter Task");
        foreach $power (@power_users) {
            $permissions->addUser("$power");
        }
        $permissions->addUser($ENV{GK_USER}) if (defined $ENV{GK_USER});
        $permissions->addOperation("TaskAdmin");
        $task->add($permissions);
    }
    else {
      $permissions = Permissions->new();
        $permissions->addComment("Adding Admin users as Taskadmin for this Task");
        foreach $admin (@admin_users) {
            $permissions->addUser("$admin");
        }
        $permissions->addOperation("TaskAdmin");
        $task->add($permissions);
      }


    # Write The Task File
    $task->write("$task_file");

}
###---------------------------------------------------------------------------------------------------
### get_nbfeeders()
###   Get NBFeeder information for the current HOST
###---------------------------------------------------------------------------------------------------
sub get_nbfeeders {

    # Get the Object Reference
    my ( $self, $objRef, $ward, $conf ) = @_;
    my @temp;
    my $feeder;
    my $target;

    #Look in nbtarget and get feeder information
    if ( -e "$ENV{'HOME'}/.nbtarget" ) {
        open( NBTARGET, "$ENV{'HOME'}/.nbtarget" );
        while (<NBTARGET>) {
            chomp $_;
            @temp = split( /:/, $_ );
            $temp[6] =~ s/\|/ /g;
            $temp[@temp] = $temp[6];
            $temp[-1] =~ s/^.*--conf//;
            $target = "$temp[0]:$temp[1]";
            $feeder = {
                HOST          => $temp[0],    # Host Name
                CPORT         => $temp[1],    # Commands Port
                SPORT         => $temp[2],    # Request Server Port
                STATUS        => $temp[3],    # NBFeeder Status
                PID           => $temp[4],    # NBFeeder Process ID
                FEEDER_WARD   => $temp[5],    # NBFeeder WARD
                FEEDER_CMD    => $temp[6],    # NBFeeder Startup Command
                FEEDER_NAME   => $temp[7],    # NBFeeder Name
                FEEDER_GROUP  => $temp[8],    # NBFeeder Group
                FEEDER_CONF   => $temp[9],    # NBFeeder Configuration
                FEEDER_TARGET => $target,     # NBFeeder Target
            };

            # If Existing Feeder is on same Host and uses Same WARD
            # Return this feeder.
            # For MOCK match the name

            if ( $ENV{GK_EVENTTYPE} eq 'mock') {
                if ($self->{'FEEDER_NAME'} eq $feeder->{FEEDER_NAME}) {
                    $objRef->info(
                        "Found Existing Feeder for MOCK $feeder->{FEEDER_NAME} on $feeder->{HOST}: $feeder->{FEEDER_TARGET}"
                    );
                    last;
                } else {
                    undef $feeder;
                }
            }
            elsif (   ( $self->{'FEEDER_HOST'} eq $feeder->{HOST} )
                && ( $ward eq $feeder->{FEEDER_WARD} ) )
            {
                $objRef->info(
                    "Found Existing Feeder on $feeder->{HOST}:  $feeder->{FEEDER_TARGET}"
                );
                last;
            }
            else {
                # If no feeder is found, undef
                undef $feeder;
            }
        }
        close(NBTARGET);
    }

    if (!$feeder) {
        $objRef->info(
            "No matching feeder found"
        );
    }
    # Return the hash
    return $feeder;
}
###---------------------------------------------------------------------------------------------------
### start_nbfeeder()
###   Start a New Feeder on the current HOST
###---------------------------------------------------------------------------------------------------
sub start_feeder {

    # Get the Object Reference
    my ( $self, $objRef, $ward, $conf,$feeder_instance,$feeder_max ) = @_;
    my ( $cmd, @cmd_result, $rcmd, @rcmd_result, $qb_cmd );
    my $netbatch_feeder_name;
    my $nbflow_bin = "/nfs/site/gen/adm/netbatch/nbfeeder/install/$ENV{'NBFEEDER_VERSION'}/bin";
    my $feeder_properties = "$ENV{PROJ}/validation/gatekeeper/feeder.properties";

    if ( $ENV{'GK_EVENTTYPE'} ne "mock" ) {
        if (defined $feeder_instance) {
            $netbatch_feeder_name = "$ENV{PROJECT}_$ENV{GK_CLUSTER}_GK_$self->{FEEDER_HOST}_$ENV{USER}_$$\_instance$feeder_instance";
            $cmd = "$nbflow_bin/nbfeeder start --work-area $ward --server --conf $conf --properties $feeder_properties --name $netbatch_feeder_name --vmargs '-Xmx25G -Xss4m'";
        }
        else {
            $cmd = "$nbflow_bin/nbfeeder start --work-area $ward --server --conf $conf --properties $feeder_properties --vmargs '-Xmx25G -Xss4m'";
        }
    } else {
        # Use the calculated FEEDER_HOST to run feeder on ION server
        $cmd = "$nbflow_bin/nbfeeder start --target $self->{FEEDER_HOST} --name $self->{FEEDER_NAME} --work-area $ward --conf $conf";
        if ( defined $ENV{'IN_QUICKBUILD'}) {
            #$qb_cmd = "$realbin/create_feeder.pl -feeder_name $self->{FEEDER_NAME} -conf $conf -work_area $ward -debug";
            $qb_cmd = "$ENV{DATOOLS}/pkgs/fedaUtils/4.5.0/bin/create_feeder.pl";
        }
    }

    # Start the feeder in the WARD using supplied configuration.
    # Create work-area and start feeder on a remote system if
#    if ( $self->{FEEDER_HOST} ne $ENV{'HOST'} ) {
#        $rcmd = "ssh $self->{FEEDER_HOST} mkdir -p -m 0770 $ward";
#        if ( $objRef->run( $rcmd, \@rcmd_result ) != 0 ) # Create work-area on remote host
#        {
#            $objRef->error(
#"NBFeeder Work area was not created on the HOST machine ward : $self->{FEEDER_HOST}:$ward"
#            );

            # Terminate if errors encountered
#            $objRef->check_errors();
#        }
#        $rcmd = "scp -q -Q $conf $self->{FEEDER_HOST}:$conf";
#        if ( $objRef->run( $rcmd, \@rcmd_result ) != 0 )   # Copy conf file to remote host
#        {
#            $objRef->error(
#"NBFeeder Configuration File was not copied to HOST machine: $self->{FEEDER_HOST}"
#            );

            # Terminate if errors encountered
#            $objRef->check_errors();
#        }

#        $cmd = "ssh $self->{FEEDER_HOST} \"$cmd\"";
#    }

    # PRint out commandline in case something fails, this aids in debug.
    if ( defined $ENV{'IN_QUICKBUILD'}) {
        $objRef->info("Forking Command to create the feeder: $qb_cmd");
        my $ret_val = $objRef->run($qb_cmd);
        if ( $ret_val != 0) {
            my %ERRORS = (
                '10' => 'ION_CMD_CRASH',
                '20' => 'NBSTATUS_CRASH',
                '30' => 'BAD_FEEDER',
                '40' => 'BAD_SITE' ,
                '50' => 'DUPLICATE_FEEDER',
            );
            if( defined $ERRORS{$ret_val}) {
                $objRef->error("\nIssue in creating new feeder: $self->{FEEDER_NAME} using command: $qb_cmd\nReason: $ERRORS{$ret_val}. Please contact your HWKC");
              }else {  $objRef->error("Issue in creating new feeder: $self->{FEEDER_NAME} using command: $qb_cmd\n. Please contact your HWKC"); }
            exit $ret_val;
      }
    }
    else {
        $objRef->info("Forking Command to create the feeder: $cmd");
        $objRef->run($cmd);
    }

}

##---------------------------------------------------------------------------------------------------
## check_taskjob_status()
##   Checks the status of Job/Task results with those shown in Netbatch.
##    An Error is generated if there is a difference
##---------------------------------------------------------------------------------------------------

sub check_task_job_status {

    # Get the Object Reference
    my ( $self, $objRef ) = @_;

    # File Check Variables
    my $file_2_check = $ENV{'MODEL'};

    # Regression Status Variables
    my ( $rpt_count, $rpt_fail, $rpt_pass ) = ( 0, 0, 0 );
    my ($pass_rate);
    my $msg;

  # Two Type of Jobs, regressions and other.
  # For Regressions, passing status is dependent on Pass Rate, Gating, or RPT File Status.

# Dump the Tasks Original Status from NETBATCH to the log file for comparison purposes when weird errors occur
    $objRef->log(
"$self->{TASK_NAME}:NB_STATUS=$self->{NB_STATUS},Success=$self->{PASSING},Fail=$self->{FAILING}"
    );

    # For Regression Job, Process the RPT file.
    if (   ( defined $self->{REGRESS_COUNT} )
        && ( $self->{NAME} =~ /regression/ ) )    # Regression Job
    {
        $objRef->info("Regress_output for $self->{NAME} is $self->{REGRESS_OUTPUT}");
        if ( !-d $self->{REGRESS_OUTPUT} ) {
            $objRef->error("REGRESS_OUTPUT directory not created for $self->{'NAME'}");
            $objRef->check_errors();
        }
        else {

            #Logic to run summarize on REGRESS_OUTPUT and then report passing/failing test
            my $sumpath        = $self->{REGRESS_OUTPUT};
            my $pending_tests  = 1;
            my $total_tests    = 0;
            my $failing_tests  = 0;
            my $premature_exit = 0;
            my $timedout       = 0;
            my $passrate       = 0;
            my $passnum;
            my @sum_results = qw();


            my $summarize_script = "$ENV{GK_SCRIPTS_DIR}/summarize";
            if (! -e $summarize_script) {
              $objRef->warning("Summarize script not found: $summarize_script");
            }
            else {
              $objRef->info("Running $summarize_script -noss $sumpath");
            }
            if ( $objRef->run( "$summarize_script -noss $sumpath", \@sum_results ) == 0 )
            {
                foreach (@sum_results) {
                    chomp;
                    my ($tmp, $value) = split /:\s+/, $_;
                    if ( $_ =~ /Total Tests/ ) {
                        $total_tests = $value;
                    }
                    if ( $_ =~ /Pending Tests/ ) {
                        $pending_tests = $value;
                    }
                    if ( $_ =~ /Failing Tests/ ) {
                        $failing_tests = $value;
                    }
                    if ( $_ =~ /Premature Exit/ ) {
                        $timedout = $value;
                    }
                    if ( $_ =~ /PASS/ ) {
                        chomp;
                        $_ =~ m/.*:\s*(\d*.\d*)\% PASS\s*\((\d*)\/\d*\)/g;
                        $passrate = $1;
                        $passnum  = $2;

                    }
                }

            }

            chomp $pending_tests;
            $rpt_count = $total_tests;
            $rpt_pass  = $passnum;
            $rpt_fail  = $failing_tests + $premature_exit + $timedout;
            $objRef->info("rpt_count:$rpt_count rpt_pass:$passnum rpt_fail:$rpt_fail");
            if (   ( $self->{STATUS} eq "Completed" )
                || ( $self->{STATUS} eq "Canceled" )
              )    # If the Status is not skipped, process.
            {
                $objRef->info("Status is now completed or Canceled");
                my $feeder_pass_rate = $self->{PASS_RATE};
                my $feeder_regress_count = $self->{REGRESS_COUNT};
                my $feeder_failures = $self->{'FAILING'};
                my $feeder_passing = $self->{'PASSING'};
                my $feeder_total_jobs = $self->{'TOTAL_JOBS'};

                $objRef->info("From feeder query: PASS_RATE:$feeder_pass_rate");
                $objRef->info("From feeder query: REGRESS_COUNT:$feeder_regress_count");
                $objRef->info("From feeder query: FAILING:$feeder_failures");
                $objRef->info("DEBUG: From feeder query: PASSING:$feeder_passing");
                $objRef->info("From feeder query: TOTAL_JOBS:$feeder_passing");


                # Determine Regression Pass Rate
                $pass_rate = 100 * ( $feeder_passing / $feeder_regress_count );
                $objRef->info("pass_rate from feeder info: $pass_rate");
                $objRef->info("passrate from summarize: $passrate");

                if ( !$self->{GATING}
                  )    # If Not Gating, should pass regardless of run status.
                {
                    $self->set( 'STATUS', "NOT_GATING" );
                }
                elsif (( $pass_rate >= $self->{PASS_RATE} )
                    && ( $rpt_fail == $self->{FAILING} ) )

                  #     elsif($rpt_pass == $self->{REGRESS_COUNT})
                {
                    $self->set( 'STATUS', "PASSED" );
                }
                elsif (( $pass_rate >= $self->{PASS_RATE} )
                    && ( $rpt_fail != $self->{FAILING} ) )
                {

                    if (   ( $ENV{GK_EVENTTYPE} eq "release" )
                        || ( $ENV{GK_EVENTTYPE} eq "mock" ) )
                    {
                        $self->set( 'STATUS', "PASSED" );
                    }
                    else {
                        $msg =
                            "Regression failed for "
                          . $self->{TASK_NAME}
                          . ":RPT=$rpt_fail,NBFeeder="
                          . $self->{FAILING};
                        $self->set( 'STATUS',     "FAILED" );
                        $self->set( 'ERROR_DESC', $msg );
                    }
                }
                elsif (( $pass_rate < $self->{PASS_RATE} )
                    && ( $rpt_fail != $self->{FAILING} ) )
                {

                    if (   ( $ENV{GK_EVENTTYPE} eq "release" )
                        || ( $ENV{GK_EVENTTYPE} eq "mock" ) )
                    {
                        $self->set( 'STATUS', "FAILED" );
                        $msg =
                            "Regression failed for "
                          . $self->{TASK_NAME}
                          . ":RPT=$rpt_fail,NBFeeder="
                          . $self->{FAILING};
                    }
                    else {
                        my $dbg_msg = "Summarize data for mismatch for FAILS "
                        . " summarize_passrate:$passrate feeder_passrate:$feeder_pass_rate";
                        $objRef->warning($dbg_msg);
                        $dbg_msg = "Actual data for mismatch: "
                        . "pass_rate:$pass_rate feeder_pass_rate: $feeder_pass_rate";
                        $objRef->warning($dbg_msg);
                        $self->handle_fatal_mismatch($passrate, $pass_rate,$rpt_fail,$feeder_failures);

                        $msg =
                            "RPT File and NBFeeder mismatch for FAILS "
                          . $self->{TASK_NAME}
                          . ":RPT=$rpt_fail,NBFeeder="
                          . $self->{FAILING};
                        $self->set( 'STATUS',     "FAILED_NB_RPT_MISMATCH" );
                        $self->set( 'ERROR_DESC', $msg );
                    }
                }
                else {
                    if (   ( $ENV{GK_EVENTTYPE} eq "release" )
                        || ( $ENV{GK_EVENTTYPE} eq "mock" ) )
                    {
                        $self->set( 'STATUS', "FAILED" );
                    }
                    else {
                        $self->set( 'STATUS', "FAILED" );
                    }

                }

                # RPT File has been processed, issue warning for non fatal errors.
                if ( $rpt_count > $self->{REGRESS_COUNT} ) {
                    $objRef->warning(
"RPT File and NBFeeder mismatch for REGRESS COUNT  $self->{TASK_NAME}:RPT=$rpt_count,NBFeeder=$self->{REGRESS_COUNT}"
                    );
                    $self->set( 'STATUS', "PASSED" )
                }
                if ( $rpt_pass > $self->{PASSING} ) {
                    $objRef->warning(
"RPT File and NBFeeder mismatch for PASSING tests $self->{TASK_NAME}:RPT=$rpt_pass,NBFeeder=$self->{PASSING}"
                    );
                    $self->set( 'STATUS', "PASSED" );
                    $self->handle_mismatch( $objRef, $rpt_count, $rpt_pass, $rpt_fail );
                }
            }
            if ( $self->{STATUS} eq "Skipped" ) {

           # Skipped Status should say something about the Job being Gating or Not Gating.
                if ( $self->{GATING} ) {
                    $self->set( 'STATUS', "Skipped_GATING" );
                }
                else {
                    $self->set( 'STATUS', "Skipped_NOT_GATING" );
                }
            }
            if ( ( $self->{STATUS} eq "FAILED" ) && ( $timedout > 0 ) ) {
                $self->{STATUS} = "TIMEOUT";
            }
        }
    }
    else    # Non Regression Job
    {
        if ( !$self->{GATING} )    # If Not Gating, should pass regardless of run status.
        {
            $self->set( 'STATUS', "NOT_GATING" );
        }
        elsif (( $self->{PASSING} >= 1 )
            && ( $self->{FAILING} == 0 )
            && ( $self->{NB_STATUS} ne "Canceled" ) )
        {
            $self->set( 'STATUS', "PASSED" );
        }
        elsif (
            ( $self->{FAILING} >= 1 )
            && (   ( $self->{NB_STATUS} ne "Skipped" )
                && ( $self->{NB_STATUS} ne "Canceled" ) )
          )
        {
            $self->set( 'STATUS', "FAILED" );
        }
        elsif ( $self->{NB_STATUS} eq "Skipped" ) {

           # Skipped Status should say something about the Job being Gating or Not Gating.
            if ( $self->{GATING} ) {
                $self->set( 'STATUS', "Skipped_GATING" );
            }
            else {
                $self->set( 'STATUS', "Skipped_NOT_GATING" );
            }
        }
        elsif ( $self->{NB_STATUS} eq "Canceled" ) {
            $self->set( 'STATUS', "FAILED" );
        }
        elsif (( $self->{NB_STATUS} eq "Completed" )
            && ( $self->{FAILING} == 0 )
            && ( $self->{PASSING} == 0 ) )
        {
            $self->set( 'STATUS', "NB_JOB_NOT_LOADED_FAILED" );
        }
        else {
            $objRef->info(
                "Unknown Failure from Netbatch Seen  $self->{DESC}:$self->{NB_STATUS}");
            $self->set( 'STATUS', "Unknown_FAILED" );
        }

# Special Case If job is set to Force Failure, fail the job unless it is configured as non gating.
        if ( $self->{FORCED_FAIL} ) {

            # If Job is set to GATING
            if ( $self->{GATING} ) {
                $self->set( 'STATUS', "FAILED" );
            }
            else {
                $self->set( 'STATUS', "NOT_GATING" );
            }
        }
    }

    # Display Jobs Final Status
    $objRef->info("$self->{DESC}:$self->{STATUS}");
}
##---------------------------------------------------------------------------------------------------
## get_stats_from_feeder
##---------------------------------------------------------------------------------------------------
sub get_stats_from_feeder {
    my ( $self, $objRef ) = @_;
    if ( defined $self->{'STATUS'} && $self->{'STATUS'} eq 'Skipped' ) {
        $self->{WALLTIME} = 0;
    }
    $self->{JOB_RUN_STATS} =
      ",,,$self->{STATUS},$self->{NB_START_TIME},$self->{WALLTIME},;";
}

##---------------------------------------------------------------------------------------------------
## collect_build_job_stats()
##---------------------------------------------------------------------------------------------------
sub collect_build_job_stats {

    # Get the Object Reference
    my ( $self, $objRef ) = @_;
    my %month_to_num = (
        "Jan" => 1,
        "Feb" => 2,
        "Mar" => 3,
        "Apr" => 4,
        "May" => 5,
        "Jun" => 6,
        "Jul" => 7,
        "Aug" => 8,
        "Sep" => 9,
        "Oct" => 10,
        "Nov" => 11,
        "Dec" => 12
    );

    # Loop thru the Log Files
    my $logs;
    my @stats;
    my $host;

    my $log_line;
    my $log_stats;
    foreach $logs ( $self->{LOG_FILE} ) {

        # Get Host machine, strip nonessential info
        $host = `grep \"Executed on\" $logs`;
        $host =~ s/^\|\s*Executed on\s*//;
        $host =~ s/^\s*://;
        $host =~ s/Pool.*$//;
        $host =~ s/\s*//g;

        my @results = ();

        # Get Job Stats
        @stats =
`grep -e 'stage.* wallclock' -ie 'stage started ' -e "Stage '.*' started" $logs`;
        if ( scalar(@stats) == 0 ) {
            get_stats_from_feeder($self);
            return;
        }
        my $top_stage;
        my $top_stage_start_time;
        my $curr_stage_start_time;
        my $curr_stage;
        foreach $log_line (@stats) {
            chomp $log_line;
            $log_line =~ s/^$logs://;
            if ( $log_line =~
/--\s*(\w+)\s*stage\s*(\w+)\s*\w+\s*(\d+:\d+:\d+)\s*wallclock\s*\((\d+.\d+).*\)\s+--$/
              )
            {
                if ( $top_stage eq $1 ) {
                    $log_stats .=
                      "$host,$top_stage,$top_stage top,$2,$top_stage_start_time,$3,$4;";
                }
                else {
                    $log_stats .= "$host,$top_stage,$1,$2,$curr_stage_start_time,$3,$4;";
                }

            }
            elsif ( $log_line =~ /\s+Stage '(.*)' started at (.*)\s+/ ) {
                $top_stage            = $1;
                $top_stage_start_time = $2;
                $top_stage_start_time =~ s/\s+$//;

                #$top_stage_start_time =~ /\S+ (\S+) (\d+) (.*) (\d+)/;
                $top_stage_start_time =~
                  /^\s*\S+\s*(\S+)\s*(\d+)\s*(\d+:\d+:\d+)\s*(\d+)/;
                my $month = $month_to_num{$1};
                $top_stage_start_time = "$month/$2/$4 $3\n";
            }
            elsif ( $log_line =~ /--\s+(.*) stage started at (.*)\s+/ ) {
                $curr_stage            = $1;
                $curr_stage_start_time = $2;
                $curr_stage_start_time =~ s/\s+$//;

                #$curr_stage_start_time =~ /\S+ (\S+) (\d+) (.*) (\d+)/;
                $curr_stage_start_time =~
                  /^\s*\S+\s*(\S+)\s*(\d+)\s*(\d+:\d+:\d+)\s*(\d+)/;
                my $month = $month_to_num{$1};
                $curr_stage_start_time = "$month/$2/$4 $3\n";
            }
        }
    }

    # Add stats to Job Object
    $self->set( 'JOB_RUN_STATS', $log_stats );
}
##---------------------------------------------------------------------------------------------------
## collect_regress_job_stats()
##---------------------------------------------------------------------------------------------------
sub collect_regress_job_stats {

    # Get the Object Reference
    my ( $self, $objRef ) = @_;

    # Loop thru the Log Files

    my ( $host, $stage, $wallclock, $cputime, $log_stats, $testlist );
    my ( $cmd, @cmd_result );

    # Host will never be known since egression are parallel by nature.
    $host = "";
    if ( $ENV{'GK_EVENTTYPE'} eq "filter" ) {
        $stage = "filter regress";
    }
    elsif ( $ENV{'GK_EVENTTYPE'} eq "post-release" ) {
        $stage = "post regress";
    }
    else {
        $stage = "regress";
    }

    # Run Yael's Script to get test stats.
    $testlist = basename( $self->{TEST_LIST} );
    $cmd =
"/nfs/site/disks/nhm.work.063/valid/vtmb/run/clones/yaelz/procmon/collect_res/publish_regression_performance.pl ";
    $cmd .= "-dut $self->{DUT} -list $testlist ";
    $cmd .= "-model_root $ENV{'MODEL'}";
    if ( $objRef->run( $cmd, \@cmd_result ) == 0 ) {
        my ( @temp1, @temp2 );
        my (%regress_hash);
        my $i;

        @temp1 = split( /,/, $cmd_result[0] );
        @temp2 = split( /,/, $cmd_result[-1] );
        for ( $i = 0 ; $i < @temp1 ; $i++ ) {
            $regress_hash{ $temp1[$i] } = $temp2[$i];
        }
        $cputime   = $regress_hash{'cputime'};
        $wallclock = $regress_hash{'walltime'};
    }
    $log_stats = "$host,$stage,$self->{STATUS},$wallclock,$cputime";

    # Add stats to Job Object
    $self->set( 'JOB_RUN_STATS', $log_stats );
}
##---------------------------------------------------------------------------------------------------
## job_status_email()
##   Send Email to user/submitter to alert Failure has occurred.
##---------------------------------------------------------------------------------------------------
sub job_status_email {

    # Get the Object Reference
    my ( $self, $to, $from, $cc, $subject, $message ) = @_;
    my ( $sendmail, $i );

    # Send Failure Email for This Job
    $sendmail = '/usr/lib/sendmail';
    open( MAIL, "|$sendmail -oi -t" );
    print MAIL "From: $from\n";
    print MAIL "To: $to\n";
    print MAIL "CC: $cc\n";
    print MAIL "Subject: $subject\n\n";
    print MAIL "$message";
    close(MAIL);
}

sub notify_build_monitors {
    my ($self,$to,$cc,$message,$task_name ) = @_;
    my $from    =  $ENV{USER}; # Changed to ENV{USER } from "Gatekeeper_alerts\@intel.com";
    my $subject = "Failure Email Notification for Build Monitors";
    my $txt = MIME::Lite->new();
    $txt->build(
        From     => $from,
        To       => $to,
        cc       => $cc,
        Subject  => $subject,
        Type     => 'text',
        Data    => $message
    );
    $txt->send();
    return 0;
}

#----------------------------------------------------------------------------------------
# check_netbatch_settings()
#   Check the Netbatch Settings for Job.
#   This check is create to identify scenarios in which a bad combination of
#   NBPOOL, NBCLASS, and NBQSLOT is inadvertantly specified, this can lead to a job
#   hanging indefinitely.
#
#----------------------------------------------------------------------------------------
sub check_netbatch_settings {

    # Get the Object Reference
    my ( $self, $objRef, $quite_mode, $hash_ref ) = @_;

    # Setup variables for Jobs`
    my ( $operation, $response );

    # Setup Job Operation and Response
    my $loop_cnt   = 0;
    my $check_done = 0;
    do {
        $operation = new SubmitJobOperation("sleep 1");
        $operation->setOption( "class",  "\"$self->{NBCLASS}\"" );
        $operation->setOption( "qslot",  "\"$self->{NBQSLOT}\"" );
        $operation->setOption( "target", "\"$self->{NBPOOL}\"" );
        $operation->setBinaryOption("validate");

        $response = $operation->execute();

        ## Check for Errors
        if ( $response->exitStatus()->isZero() ) {
            $objRef->info(
"  NB Configuration OK for Job $self->{NAME}: $self->{NBPOOL} : $self->{NBCLASS} : $self->{NBQSLOT}"
            );

            # Save these NB settings.
            $$hash_ref{ $self->{NBPOOL} }{ $self->{NBCLASS} }{ $self->{NBQSLOT} }
              {PASSED_NB_CHECK} = 1;
            $check_done = 1;
        }
        else {
            if (   ( $response->exitStatus()->getValue() == 255 )
                || ( $response->exitStatus()->getValue() == 250 )
                || ( $response->exitStatus()->getValue() == 5 ) )
            {

                # Handle the condition when the check simply times out.
                my $loopcnt = $loop_cnt + 1;
                $objRef->info("Could not contact NB Pool Master, retry $loopcnt");
                sleep( 60 * $loop_cnt );

                if ( $loop_cnt == 7 ) {
                    $objRef->error(
"Could Not Contact Pool Master, contact GK Admin due to following command failing"
                    );
                    $objRef->error(
"Command: nbjob run --class $self->{NBCLASS} --qslot $self->{NBQSLOT} --target $self->{NBPOOL} --validate sleep 1"
                    );
                }
            }
            else {
                if ($quite_mode) {
                    $objRef->info(
                        "Netbatch Configuration for job $self->{NAME} is not supported.");
                    $objRef->info(
" NBPOOL = $self->{NBPOOL} : NBCLASS = $self->{NBCLASS}: NBQSLOT = $self->{NBQSLOT}"
                    );
                    $objRef->info("NBAPI: $response->{output}->{lines}[0]");
                }
                elsif ( defined $self->{DISABLE_NB_CHECK} ) {
                    $objRef->warning(
"Netbatch Configuration for job $self->{NAME} is not supported. The check has been disabled"
                    );
                    $objRef->warning(
" NBPOOL = $self->{NBPOOL} : NBCLASS = $self->{NBCLASS}: NBQSLOT = $self->{NBQSLOT}"
                    );
                    $objRef->info("NBAPI: $response->{output}->{lines}[0]");
                }
                else {
                    $objRef->error(
                        "Netbatch Configuration for job $self->{NAME} is not supported.");
                    $objRef->error(
" NBPOOL = $self->{NBPOOL} : NBCLASS = $self->{NBCLASS}: NBQSLOT = $self->{NBQSLOT}"
                    );
                    $objRef->info("NBAPI: $response->{output}->{lines}[0]");
                }

                # Exit loop on any known or unknown error.
                $check_done = 1;
            }
        }

        #    } while(!$response->exitStatus()->isZero() && $loop_cnt++ < 8);
      } while ( !$response->exitStatus()->isZero()
        && ( $loop_cnt++ < 8 )
        && ( $check_done == 0 ) );

    # Terminate on errors
    $objRef->check_errors();
}

#----------------------------------------------------------------------------------------
# delete_task()
#   Delete the task from the NBFeeder.
#   The Deletion will be a multi step process.
#   Step 1 will be to stop the task to ensure all running jobs are canceled.
#   Step 2 will be a delete command.
#   Step 3 if the job is still present, issue  a forced delete.
#----------------------------------------------------------------------------------------
sub delete_task();
{

    # Get the Object Reference
    my ( $self, $objRef, $quite_mode, $hash_ref ) = @_;

    # Setup variables for Jobs`
    my ( $operation, $response );

    # Setup Job Operation and Response

}

#----------------------------------------------------------------------------------------
# validate_netbatch_settings()
#   Check the Netbatch Settings for Task.
#   This check is create to identify scenarios in which a bad combination of
#   NBPOOL, NBCLASS, and NBQSLOT is inadvertantly specified, this can lead to a job
#   hanging indefinitely.
#   This is a new check developed by NBFlow team to work around issues with nbjob run ** sleep 1
#
#----------------------------------------------------------------------------------------
sub validate_netbatch_settings {

    # Get the Object Reference
    my ( $self, $objRef, $quiet_mode, $hash_ref ) = @_;

    # Setup variables for Jobs
    my ( $operation, $response );
    my $message          = "";
    my $loop             = 0;
    my $user             = $ENV{USER};
    my $pool             = $self->{NBPOOL};
    my $class            = $self->{NBCLASS};
    my $qslot            = $self->{NBQSLOT};
    my $pool_qslot_valid = 0;
    my $class_pool_valid = 0;

    for ( my $loop = 0 ; $loop < 4 ; $loop++ ) {
        $objRef->info("  $loop times thru loop");
        $response = &get_status( "qslots", $pool,
            "hasPermissions('$user') && (name=='$qslot' || alias=='$qslot')" );
        if ( $response->exitStatus()->isZero() ) {

# Modified the code slightly from what NBFlow team developed which is commented out below.
# Original implementation verified qslot and pool, then exited.
            if ( $response->outputSet()->getSize() <= 0 ) {
                $response =
                  &get_status( "qslots", $pool, "name=='$qslot' || alias=='$qslot'" );
                if ( $response->outputSet()->getSize() <= 0 ) {
                    $objRef->info("  Qslot $qslot doesn't exist in $pool");
                }
                else {
                    $objRef->info(
                        "  User doesn't have permissions in qslot $qslot in $pool");
                }
            }
            else {
                $objRef->info("  User does have permissions in qslot $qslot in $pool");
                $pool_qslot_valid = 1;
            }
        }
        else {
            $objRef->info("  Pool/Qslot Check NBAPI: $response->{output}->{fields}[0]");
            if ( !defined $response->{output}->{fields}[0] ) {
                $objRef->info(
"  Pool/Qslot Check NBAPI response not defined: $ENV{'GK_CLUSTER'} $ENV{'GK_STEP'}"
                );
                print
"    Pool/Qslot Check NBAPI response not defined: $ENV{'GK_CLUSTER'} $ENV{'GK_STEP'}\n";
            }
        }

        $response = &get_status( "workstations", $pool, $class );

        if ( $response->exitStatus()->isZero() ) {
            if ( $response->outputSet()->getSize() == 0 ) {
                $objRef->info("  Class $class is not supported in $pool");
            }
            else {
                $objRef->info("  Class $class is  supported in $pool");
                $class_pool_valid = 1;
            }
        }
        else {
            $objRef->info("  Class/Pool NBAPI: $response->{output}->{fields}[0]");
        }

        # Successfully Verified NB Settings, exit loop.
        if ( $pool_qslot_valid && $class_pool_valid ) {
            $objRef->info("  NB Configuration OK for Pool/Qslot & Class/Pool");
            last;
        }
        $objRef->info("");
        sleep( 01 * $loop );
    }

    if ( !$pool_qslot_valid && !$class_pool_valid ) {
        if ($quiet_mode) {
            $objRef->info(
                "Netbatch Configuration for job $self->{NAME} is not supported.");
            $objRef->info(
" NBPOOL = $self->{NBPOOL} : NBCLASS = $self->{NBCLASS}: NBQSLOT = $self->{NBQSLOT}"
            );
            $objRef->info("NBAPI: $response->{output}->{fields}[0]");
        }
        else {
            $objRef->error(
                "Netbatch Configuration for job $self->{NAME} is not supported.");
            $objRef->error(
" NBPOOL = $self->{NBPOOL} : NBCLASS = $self->{NBCLASS}: NBQSLOT = $self->{NBQSLOT}"
            );
            $objRef->info("NBAPI: $response->{output}->{fields}[0]");
        }
    }
    elsif ( !$pool_qslot_valid && $class_pool_valid ) {
        if ($quiet_mode) {
            $objRef->info(
                "Netbatch Configuration for job $self->{NAME} is not supported.");
            $objRef->info(
" NBPOOL = $self->{NBPOOL} : NBCLASS = $self->{NBCLASS}: NBQSLOT = $self->{NBQSLOT}"
            );
            $objRef->info("NBAPI: $response->{output}->{fields}[0]");
        }
        else {
            $objRef->error(
                "Netbatch Configuration for job $self->{NAME} is not supported.");
            $objRef->error(
" NBPOOL = $self->{NBPOOL} : NBCLASS = $self->{NBCLASS}: NBQSLOT = $self->{NBQSLOT}"
            );
            $objRef->info("NBAPI: $response->{output}->{fields}[0]");
        }
    }
    elsif ( $pool_qslot_valid && !$class_pool_valid ) {
        if ($quiet_mode) {
            $objRef->info(
                "Netbatch Configuration for job $self->{NAME} is not supported.");
            $objRef->info(
" NBPOOL = $self->{NBPOOL} : NBCLASS = $self->{NBCLASS}: NBQSLOT = $self->{NBQSLOT}"
            );
            $objRef->info("NBAPI: $response->{output}->{fields}[0]");
        }
        else {
            $objRef->error(
                "Netbatch Configuration for job $self->{NAME} is not supported.");
            $objRef->error(
" NBPOOL = $self->{NBPOOL} : NBCLASS = $self->{NBCLASS}: NBQSLOT = $self->{NBQSLOT}"
            );
            $objRef->info("NBAPI: $response->{output}->{fields}[0]");
        }
    }
    else {
        $objRef->info(
"  NB Configuration OK for Job $self->{NAME}: $self->{NBPOOL} : $self->{NBCLASS} : $self->{NBQSLOT}"
        );
    }

    # Terminate on errors
    $objRef->check_errors();
}

sub get_status {
    my $type   = shift;
    my $target = shift;
    my $filter = shift;

    my $operation = new StatusOperation($type);
    $operation->setOption( "target", $target );
    $operation->setFilter($filter);
    return $operation->execute();

}

sub regress_output_summary {

    my ( $self, $objRef ) = @_;

    my $file_2_check = $ENV{'MODEL'};
    my ( $rpt_count, $rpt_fail, $rpt_pass ) = ( 0, 0, 0 );
    my ($pass_rate);
    my $msg;
    $objRef->set( 'QUIET', 1 ) if !$ENV{'DISABLE_QUIET_MODE'};

    if (   ( defined $self->{REGRESS_COUNT} )
        && ( $self->{NAME} =~ /regression/ ) )    # Regression Job
    {
        $objRef->info("Regress_output for $self->{NAME} is $self->{REGRESS_OUTPUT}");
        if ( !-d $self->{REGRESS_OUTPUT} ) {
            $objRef->error("REGRESS_OUTPUT directory not created for $self->{'NAME'}");
            $objRef->check_errors();
        }
        else {

            #Logic to run summarize on REGRESS_OUTPUT and then report passing/failing test
            my $sumpath        = $self->{REGRESS_OUTPUT};
            my $pending_tests  = 1;
            my $total_tests    = 0;
            my $failing_tests  = 0;
            my $premature_exit = 0;
            my $timedout       = 0;
            my $passrate       = 0;
            my $passnum;
            my @sum_results = qw();

            my $summarize_script = "$ENV{GK_SCRIPTS_DIR}/summarize";
            if (! -e $summarize_script) {
              $objRef->warning("Summarize script not found: $summarize_script");
            }
            else {
              $objRef->info("Running $summarize_script -noss $sumpath");
            }
            if ( $objRef->run( "$summarize_script -noss $sumpath", \@sum_results ) == 0 )
            {
                foreach (@sum_results) {
                    my $tmp;
                    chomp;
                    ( $tmp, $total_tests ) = split /:\s+/, $_ if ( $_ =~ /Total Tests/ );
                    ( $tmp, $pending_tests ) = split /:\s+/, $_
                      if ( $_ =~ /Pending Tests/ );
                    ( $tmp, $failing_tests ) = split /:\s+/, $_
                      if ( $_ =~ /Failing Tests/ );
                    ( $tmp, $timedout ) = split /:\s+/, $_ if ( $_ =~ /Timed Out/i );
                    ( $tmp, $premature_exit ) = split /:\s+/, $_
                      if ( $_ =~ /Premature Exit/ );
                    if ( $_ =~ /PASS/ ) {
                        chomp;
                        $_ =~ m/.*:\s*(\d*.\d*)\% PASS\s*\((\d*)\/\d*\)/g;
                        $passrate = $1;
                        $passnum  = $2;

                    }
                }

            }

            chomp $pending_tests;
            $rpt_count = $total_tests;
            $rpt_pass  = $passnum;
            $rpt_fail  = $failing_tests + $premature_exit + $timedout;

    #my $msg = " Passed Tests=$passnum, Failed Tests=$rpt_fail, Total Tests=$total_tests";

            if ( $rpt_fail >= 1 ) {
                $msg = " Check path $sumpath for failure details\n";
            }

            return $msg;

        }
    }
}

##---------------------------------------------------------------------------------------------------
## parent_task_status()
##   Returns the Status of the Parent Task and all Sub-Tasks in NBFeeder.
##---------------------------------------------------------------------------------------------------
sub parent_task_status {

    # Get the Object Reference
    my ( $self, $objRef, $objSubTask ) = @_;

    # Setup variables for NBFeeder Task Status
    my ( $task_name, $task_path, $operation, $response, $output );

    # Setup variables for determine Task time stats in seconds
    my ( $start_time, $end_time, $total_time );
    my ($feeder_lost) = 0;

    # Initialize FEEDER Status to Not Connected.
    $self->set( 'FEEDER_STATUS', undef );

    $task_name = $self->{TASK_NAME};
    $task_path = $self->{TASK_PATH};
    $task_path = "/${task_path}" if ( $task_path !~ m|^/| );
    $objRef->debug("Checking for status of ${task_name} with path ${task_path}");

    $operation = new StatusOperation("tasks");
    $operation->setFields(
"TaskID,Task,AbsolutePath,Status,TotalJobs,LocalWaitingJobs,RemoteWaitingJobs,RunningJobs,SuccessfulJobs,FailedJobs,SkippedJobs,Submitted,Started,Finished,TimesRestarted,ExitStatus,WaitReason,JobsWaitReason"
    );
    $operation->setFilter("startswith(AbsolutePath, '${task_path}')");
    $operation->setTarget( $self->{FEEDER_TARGET} );
    $operation->setOption( "timeout" => 900 );

    $objRef->debug( "Executing Command Line: " . $operation->buildCommandLine() );
    $response = $operation->execute();
    $output   = $response->outputSet();

    my %task_hash = ();
    if ( $objSubTask && ( ( ref $objSubTask ) eq 'ARRAY' ) ) {
        $task_hash{ $_->{TASK_PATH} } = $_ foreach (@$objSubTask);
    }
    $task_hash{ $self->{TASK_PATH} } = $self;

    $objRef->debug( "Checking status of " . ( scalar keys %task_hash ) . " tasks" );

    my %found_tasks    = ();
    my $num_lost_tasks = 0;

    # If Response returns, set attributes of jobs object.
    # Two types of jobs can be seen in his subroutine.
    # 1) A Zombie job which was submitted by a previous process.
    # 2) A Job submitted by the current process.
    $output->beforeFirst();
    while ( $output->next() ) {
        my $task_path = $output->getField('AbsolutePath');
        if ( $task_path && ( exists $task_hash{$task_path} ) && $task_hash{$task_path} ) {
            my $task   = $task_hash{$task_path};
            my $active = !( defined $task->{STATUS} );

            if ( ( !defined $task->{NB_STATUS} ) && $output->getField('TaskID') ) {

                # New Job, but could have a Zombie Alias

                $found_tasks{$task_path}++;
                $objRef->debug( "Setting TASK_ID for new job (${task_path}): "
                      . $output->getField('TaskID') );
                $task->set( 'TASK_ID', $output->getField('TaskID') );
            }
            elsif ( $output->getField('TaskID') ) {

                # Job submitted by Current Process

                $found_tasks{$task_path}++;
                my $retries = $output->getField('TimesRestarted');

                my ( $task_wait, $jobs_wait );
                $task_wait = $output->getField('WaitReason')     || "";
                $jobs_wait = $output->getField('JobsWaitReason') || "";
                my $wait_reason = $task_wait || $jobs_wait;

                my $status = $output->getField('Status');

                $task->set( 'WAIT_LOCAL',  $output->getField('LocalWaitingJobs') );
                $task->set( 'WAIT_REMOTE', $output->getField('RemoteWaitingJobs') );
                $task->set( 'WAITING',     $task->{WAIT_LOCAL} + $task->{WAIT_REMOTE} );
                $task->set( 'WAIT_REASON', $wait_reason );

                $task->set( 'NB_STATUS', $status );
                $task->set( 'RUNNING',   $output->getField('RunningJobs') );
                $task->set( 'PASSING',   $output->getField('SuccessfulJobs') );
                $task->set( 'FAILING',   $output->getField('FailedJobs') );
                $task->set( 'SKIPPED',   $output->getField('SkippedJobs') );
                $task->set( 'TOTAL_JOBS',$output->getField('TotalJobs') );

                $task->set( 'FEEDER_STATUS', "Running" );

                # Upon a successful Read. Reset the Feeder Lost var.
                $task->set( 'FEEDER_LOST',       $feeder_lost );
                $task->set( 'NB_SUBMITTED_TIME', $output->getField('submitted') );

                if ( $retries > $task->{NB_RETRIES}
                    && ( $status !~ m/^(?:Stop|Cancel|Delet)/ ) )
                {

                    if ( !$active ) {
                        $objRef->debug(
                            "Found Status ${status} for completed job (${task_path})");

          # If a job is in a non-final state after being finished, unset the STATUS field.
                        $task->set( 'STATUS', undef );
                    }
                    $task->set( 'NB_RETRIES', $retries );
                    $objRef->info(
"Found Retried Task:$task->{TASK_NAME}, TaskID:$task->{TASK_ID}, Retry:$task->{NB_RETRIES}"
                    );
                }

                if (   ( $status eq "Completed" )
                    || ( $status eq "Skipped" )
                    || ( $status eq "Canceled" ) )
                {
                    $objRef->debug("Found Status ${status} for job (${task_path})");
                    $task->set( 'NB_EXIT_STATUS', $output->getField('ExitStatus') );

                    # Once a job is finished, set the STATUS field.
                    if ($active) {
                        $task->set( 'STATUS', $status );
                        $objRef->debug(
"Task:$task->{TASK_NAME}, TaskID:$task->{TASK_ID}, Status:$task->{STATUS}"
                        );
                    }
                }

                # If Job has started, capture Start Time.
                if ( defined $output->getField('Started') ) {
                    $task->set( 'NB_START_TIME', $output->getField('Started') );
                }

                # If Job has completed, capture End Time.
                if ( defined $output->getField('Finished') ) {
                    $task->set( 'NB_END_TIME', $output->getField('Finished') );

                    # Determine the Wall Clock time for this job.
                    $start_time = parse_nb_time( $task->{NB_START_TIME} );
                    $end_time   = parse_nb_time( $task->{NB_END_TIME} );

                    if ( defined $start_time && defined $end_time ) {

                        # Calculate Walltime and save.
                        $total_time = $end_time - $start_time;
                        $task->set( 'WALLTIME', $total_time );
                    }
                }
            }
        }
    }

    foreach my $task_path ( keys %task_hash ) {
        if ( !( exists $found_tasks{$task_path} ) ) {
            my $task = $task_hash{$task_path};
            $num_lost_tasks++;

            if ( !( defined $task->{STATUS} ) && ( defined $task->{NB_STATUS} ) ) {

            # Only for Jobs which have been checked by API's before but are not completed.
                $feeder_lost = $task->{FEEDER_LOST} + 1;
                if ( $feeder_lost % 1 == 0 ) {
                    $task->set( 'FEEDER_LOST', $feeder_lost );
                    $task->set( 'NB_STATUS',   "LOST NBFEEDER Connection" );
                }
            }

            $objRef->debug("Failed to get status of task ${task_path}");
        }
    }

    if ($num_lost_tasks) {
        $objRef->debug("Failed to get status of ${num_lost_tasks} tasks");
        $objRef->debug( "Executed Command: " . $operation->buildCommandLine() );
        for ( my $i = 0 ; $i < $output->getSize() ; ++$i ) {
            chomp( my $line = $output->getLineAt($i) );
            $objRef->debug("NBAPI OUTPUT: ${line}");
        }
    }
}

##---------------------------------------------------------------------------------------------------
## parse_nb_time()
##   Returns the GMT time of a netbatch time string
##---------------------------------------------------------------------------------------------------
sub parse_nb_time {
    my ($time_str) = @_;
    my $time = 0;
    if ( $time_str =~ m|(\d+)/(\d+)/(\d+)\s*(\d+):(\d+):(\d+)| ) {

        # Example: 08/18/2011 23:10:33
        # timegm expects months to be in range of 0 .. 11, this is why we have $month-1
        #               seconds, minutes, hours, day, month - 1, year);
        $time = timegm( $6, $5, $4, $2, $1 - 1, $3 );
    }

    return $time;
}
sub handle_mismatch {
    my ($self, $objRef, $rpt_count, $rpt_pass, $rpt_fail) = @_;
    my $operation = new StatusOperation("jobs");
    $operation->setFields("Jobid,Status,ExitStatus,JobStatus,TestRegressDir");
    $operation->setFilter("basetask($self->{TASK_ID})");
    $operation->setOption("target", $self->{FEEDER_TARGET});
    my $response = $operation->execute();
    if(! defined $response) {
        $objRef->warning("nbstatus jobs command did not return any data");
        return;
    }else{
        $objRef->warning("Got results for $self->{TASK_ID}");
    }
    my $print_str = &output($objRef, $response);

    my $email_list = "jennifer.a.johnson\@intel.com";
    my $subject = "GOT NON_FATAL MISMATCH error for $self->{TASK_ID}";

    $self->job_status_email($email_list, $email_list, $email_list, $subject,$print_str);
}
sub handle_fatal_mismatch {
    my ($self, $objRef, $sum_passrate, $feed_passrate, $rpt_fail,$feeder_fail) = @_;

    my $email_list = "jennifer.a.johnson\@intel.com";
    my $subject = "GOT FATAL MISMATCH error for $self->{TASK_NAME}";

    my $print_str = "summarize passrate: $sum_passrate\n"
    . "calculated from feeder data: $feed_passrate\n"
    . "summarize failures: $rpt_fail\n"
    . "feeder failures: $feeder_fail\n";

    $self->job_status_email($email_list, $email_list, $email_list, $subject,$print_str);
}

sub output
{
    my ($objRef, $response) = @_;

    $objRef->warning("Getting more information non-fatal FAILED_NB_RPT_MISMATCH error");

    my $output = $response->outputSet();

    my @fields = $output->getFields();
    my $print_str = "Output content\n";

    $output->beforeFirst();
    while ($output->next())
    {
        $print_str .= "{\n";
        foreach my $field (@fields)
        {
            my $value = $output->getField($field) || "N/A";
            $print_str .= "$field = " . $value . "\n";
        }
        $print_str .= "}\n\n";
    }
    $objRef->warning($print_str);
    return $print_str;
}
1;
