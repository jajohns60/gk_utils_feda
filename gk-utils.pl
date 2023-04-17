#!/usr/intel/pkgs/perl/5.14.1/bin/perl
#----------------------------------------------------------------------------------------
# Environment Setup
#----------------------------------------------------------------------------------------
use strict;    # Use strict syntax pragma
no warnings 'recursion';

use Data::Dumper;
use Data::Compare;
use vars qw($ProgramName $ProgramDir $feeder_instance $feeder_max);
use Time::Local;
use Tie::File;
use FindBin qw($Bin); # This script location
use File::Basename;
use File::Spec qw(catfile);
use List::MoreUtils qw(indexes);
use FindBin;
use lib $FindBin::Bin;
use lib "$FindBin::Bin/lib";

BEGIN {
    ( $ProgramDir, $ProgramName ) = ( $0 =~ m|^(.+)/([^/]+)$| );
    $ProgramName ||= $0;
    $ProgramDir  ||= ".";
    unshift @INC, $ProgramDir;
}

#Initialize the Tool
our %GkConfig;
our $gkconfigdir = $ENV{GK_CONFIG_DIR};

my $DisableTaskCreation;
my $PreBuildRegress = 0;
&init_tool();

#----------------------------------------------------------------------------------------
# Required Libraries
#----------------------------------------------------------------------------------------
use sigtrap qw(die untrapped normal-signals error-signals);
use File::Basename;    # For basename()
use File::Spec::Functions qw(catfile catdir updir);
use Cwd 'abs_path';    # To get current dir with getcwd()
use lib $ProgramDir;
use VTMBObject;        # VTMB Object
use VTMBTool;          # VTMB Tool Object
use VTMBCmdline;       # VTMB Commandline Line Object
use VTMBLog;           # VTMB Log Object
#use VTMBJob;                   # VTMB Job Object
require VTMBJob;       # VTMB Job Object

#-------------------------------------------------------------------------------
## Global Variables
##-------------------------------------------------------------------------------
my $VTMBObj;
my $VTMBTool;
my $VTMBCmdline;
my $VTMBLog;
my $VTMBJob;
my ( @VTMBJobs, @VTMBJobsPost, %VTMBJobsMap );
my @envVars;           # Environment variables used
my $workdir = $ENV{PWD};
our $GkEventType;
my %all_job_names;
my %job_2_task_names;
my ( $nbfeeder_conf, $nbfeeder_ward, $nbfeeder_target );
my ( $job_report, $job_report_old );
my $sleep_cycle;
my $timeout;
my $jobs_launched  = 0;
my $print_commands = 0;
my (%netbatch_settings);
my $clone_in_clone = 0;
my $clone_in_clone_paths;
my %regress_perf_data;
my $disable_nb_check;
my $cp_cmd = "/bin/cp -f";
######################################################### REMOVED 10/5/2010
########Variabled moved to GKUtils CFG file.
#######NBFeeder LOG History Depth
#######$ENV{'__NBFEEDER_LOG_HISTORY_SIZE'} = 30;
#######$ENV{'NBFLOW_PATCH_LIST'}           = "nbflow_1.3.1_build_0120_00_cp33.jar";
#########################################################

# Our for Variables which are defined in configuration files.
our %Models;
our $netbatch_override;

## Workaround for Gatekeeper bug. $RTLD_DEEPBIND must be set to 0 to ensure
## compatibility with Spyglass LP and VC LP
$ENV{RTLD_DEEPBIND} = 0;
# Disable CENTRAL_ROOT
$ENV{'BKU_NO_CENTRAL_ROOT'} = 1;
$ENV{'GK_SMART_MODE'}       = 0;

if ( $GkEventType eq "FILTER" || (($GkEventType eq "TURNIN") && (defined $Models{enable_gk_smart_build_in_integrate}) )) {
    if ( $Models{enable_gk_smart_build} ) {
        $ENV{'GK_SMART_MODE'} = 1;
        if ( $Models{enable_gk_smart_build2} ) {
            $ENV{'GK_SMART2_MODE'} = 1;
        }
    }
}

#Our for content based smart build and regress
our %RunStages;
our @smart_buildable_paths = ( "src", "cfg/dut" );
our $build_all             = 1;
our %dut_contexts          = ();
our @fileschanged;

# Smart waiver variables
my @smart_waivers;
my %smart_waiver_tree;
#----------------------------------------------------------------------------------------
# Execution
#----------------------------------------------------------------------------------------
## Turn Off All Messages to STDOUT.
#$VTMBTool->set( 'QUIET', 1 );

&job_run_info();

&check_environment();

# Actually this is the model path not regress path
our $regress_path = $VTMBObj->get('MODEL');
$VTMBTool->info("The model path is $regress_path\n");
chomp $regress_path;
our $rid = $regress_path;
$rid =~ s/^.*\/([^\/]*)$/$1/;
# Code for GK Bundle file changed
if (defined $ENV{GK_TURNIN_FILES_CHANGED})
{
   my @list_of_fc = split /\s/, $ENV{GK_TURNIN_FILES_CHANGED};
   my $dest = "$ENV{GK_WORK_AREA}/.bundle_files_changed";
   foreach (@list_of_fc)
   {
       chomp $_;
       my $cmd = "cat $_ >> $dest";
       $VTMBTool->run($cmd);
   }
   $ENV{GK_BUNDLE_FILES_CHANGED} = $dest;
}

#Calling GK Smart build for filter
&gk_smart_build() if ( $ENV{GK_SMART_MODE} && ( !$PreBuildRegress ) );

our $run_fact = 1;
$VTMBTool->info("Initial FACT to be run status: $run_fact");
if (( $GkEventType eq "FILTER") || ($GkEventType eq "TURNIN" ))
{
    $run_fact = &check_run_fact();
}
$VTMBTool->info("Final FACT to be run status: $run_fact");
$VTMBTool->log("Final FACT to be run status: $run_fact");
our @norun_array;
if (( $GkEventType eq "MOCK") && (defined $ENV{GK_NORUN_REGEX} ))
{
    my @tmp = split /,/, $ENV{GK_NORUN_REGEX};
    foreach my $regex (@tmp)
    {
       $regex =~ s/^\s*//g;
       $regex =~ s/\s*$//g;
       push @norun_array, $regex;
    }
}
# Enabling caching in GK #########################
$ENV{GK_CACHE_PATH} = "/some/non/existing/location";
my $cache_applicable = &check_if_cache_applicable();
if ($cache_applicable)
{
   &find_appropriate_cache();
}
$VTMBTool->info("GK Golden path - $ENV{GK_CACHE_PATH}\n");
$VTMBTool->log("GK Golden path - $ENV{GK_CACHE_PATH}\n");

# Short Cut to enable development of Cradle to Grave Stats, allows for quick rerun in a completed area.
if ( defined $VTMBCmdline->value('-stats') ) {
    my $fname =
      $VTMBObj->get('MODEL') . "/GATEKEEPER" . "/vtmbjob.$ENV{'GK_EVENTTYPE'}.pl";
    open DATA, "<$fname" or $VTMBTool->error("Failed to open $fname: $!");
    {
        local $/;
        my $VTMBJobs;
        eval <DATA>;
        @VTMBJobs = @{$VTMBJobs};
    }
    close DATA;
    $VTMBTool->check_errors();
    &generate_gk_stats( $Models{stats}{ $ENV{'SITE'} } );
    exit(0);
}

# Short Cut to enable development of Regression Stats, allows for quick rerun in a completed area.
if ( defined $VTMBCmdline->value('-regress_stats') ) {
    my $fname =
      $VTMBObj->get('MODEL') . "/GATEKEEPER" . "/vtmbjob.$ENV{'GK_EVENTTYPE'}.pl";
    open DATA, "<$fname" or $VTMBTool->error("Failed to open $fname: $!");
    {
        local $/;
        my $VTMBJobs;
        eval <DATA>;
        @VTMBJobs = @{$VTMBJobs};
    }
    close DATA;
    $VTMBTool->check_errors();
    &generate_regression_perf_data( \@VTMBJobs );
    exit(0);
}

# Add Pre Turnin Jobs
push( @VTMBJobs, &GeneralJobs("pre_turnin") );
#print Dumper @VTMBJobs;
# Build Jobs(Simbuild Commands)
push( @VTMBJobs, &BuildModels );
#print Dumper @VTMBJobs;
# General Jobs(Non-Simbuild Commands)
push( @VTMBJobs, &GeneralJobs("general_cmds") );

# Post Jobs(Non-Simbuild Commands)
push( @VTMBJobsPost, &GeneralJobs("post_cmds") );

# Regression Jobs(Simregress Commands)
if ( !defined $VTMBCmdline->value('-build_only') ) {
    @VTMBJobs = &CreateRegressions();
}

#Pruning @VTMBjobs. Once all Jobs are part of @VTMBJobs, see each job's dependency. If the dependency they are dependent on is not present, then remove the job. This will serve multiple purpose. Do this only when $VTMBJob->{'SMART'} = 1 - else it will not catch real depedencies missing.
#1. Compliments Smart build and extends to general_cmds
@VTMBJobs = &PruneVTMBJobs();

# Launch & Monitor Jobs if Not PRINT_COMMANDS
if ( !$print_commands ) {

    # Dump Netbatch Settings for use in Global Override.
    &dump_netbatch_settings( \%netbatch_settings, "netbatch_override" );
    @VTMBJobs = &CreateNestedTask();

    if ( $ENV{GK_NO_RUN} ) {
        $VTMBTool->debug( $_->{NAME} ) foreach (@VTMBJobs);
    }
    else {
        &LaunchMonitorJobs();
    }
}
else {
    &PrintCommands();
}

if ( !$PreBuildRegress ) {
    &open_model_dir();
}

## Exit the Program
$VTMBTool->terminate();    # Destory objects and exit

#----------------------------------------------------------------------------------------
# Subroutine Section
#----------------------------------------------------------------------------------------
#----------------------------------------------------------------------------------------
# init_tool()
#    Initializes the tool by creating a global tool object
#     Sets up the HSW Environment
#----------------------------------------------------------------------------------------
sub init_tool {
    my ( $cmd, @cmd_results );
    my ( $var, $val );
    my $path_var;

    # Detemine GK Utils Version
    $ENV{'GK_UTILS_DIR'} = abs_path($ProgramDir);
    $ENV{'GK_UTILS_VER'} = basename( abs_path($ProgramDir) );
    $ENV{'GK_UTILS_VER'} =~ s/\///g;

    # Create tool object or die
    $VTMBTool = new VTMBTool(
        NAME              => 'gk-utils',
        QUIET             => 1,
        TOOL_MSG_SUPPRESS => 1,
    ) or die "Error initializing VTMBTool object.  Report this bug to DA.\n";

    # Display status and set up indentation
    $VTMBTool->indent_msg(0);
    $VTMBTool->info("Setting up VTMBTool Object ...");
    $VTMBTool->indent_msg(2);

    # Parse the Commandline
    # This also sets certain environment variabvles like GK_CLUSTER and GK_STEPPING
    #  for cases in which gk-utils is being run from commandline.
    &parse_cmdline();

    # Turn Off All Messages to STDOUT.
    $VTMBTool->set( 'QUIET', 1 );

    # Turn off all tool specific message prepend information.
    $VTMBTool->set( 'TOOL_MSG_SUPPRESS', 1 );

    # Disable quiet mode based on ENV vars
    if ( $ENV{'DISABLE_QUIET_MODE'} ) {
        $VTMBTool->set( 'QUIET',             0 );
        $VTMBTool->set( 'TOOL_MSG_SUPPRESS', 0 );
    }

    # Access the GK Configuration File to determine rtl.rc and other information.
    # Require this file

    my $gk_cfgfile;
    if (
        -e "$ENV{GK_CONFIG_DIR}/GkConfig.$ENV{'PROJECT'}.$ENV{'GK_STEP'}.$ENV{'GK_CLUSTER'}.pl"
      )
    {
        $gk_cfgfile =
"$ENV{GK_CONFIG_DIR}/GkConfig.$ENV{'PROJECT'}.$ENV{'GK_STEP'}.$ENV{'GK_CLUSTER'}.pl";
        $VTMBTool->info("Found GKConfig with Stepping and Cluster Specification");
    }
    elsif ( -e "$ENV{GK_CONFIG_DIR}/GkConfig.$ENV{'PROJECT'}.$ENV{'GK_STEP'}.pl" ) {
        $gk_cfgfile = "$ENV{GK_CONFIG_DIR}/GkConfig.$ENV{'PROJECT'}.$ENV{'GK_STEP'}.pl";
        $VTMBTool->info("Found GKConfig with Stepping Specification");
    }
    elsif ( -e "$ENV{GK_CONFIG_DIR}/GkConfig.$ENV{'PROJECT'}.$ENV{'GK_CLUSTER'}.$ENV{'GK_BRANCH'}.pl" ) {
        $gk_cfgfile = "$ENV{GK_CONFIG_DIR}/GkConfig.$ENV{'PROJECT'}.$ENV{'GK_CLUSTER'}.$ENV{'GK_BRANCH'}.pl";
        $VTMBTool->info("Found GKConfig with Branch Specification");
    }
    elsif ( -e "$ENV{GK_CONFIG_DIR}/GkConfig.$ENV{'PROJECT'}.$ENV{'GK_CLUSTER'}.pl" ) {
        $gk_cfgfile = "$ENV{GK_CONFIG_DIR}/GkConfig.$ENV{'PROJECT'}.$ENV{'GK_CLUSTER'}.pl";
        $VTMBTool->info("Found GKConfig with Project Specification");
    }
    else {
        $gk_cfgfile = "$ENV{GK_CONFIG_DIR}/GkConfig.$ENV{'PROJECT'}.pl";
        $VTMBTool->info("Found GKConfig with No Specification");
    }
    $VTMBTool->info("Requiring $gk_cfgfile");
   # print $gk_cfgfile;
    require "$gk_cfgfile";
    # Check Path and Insure "." is always on the path.
    # If it is not, place it on the path.
    $path_var = $ENV{'PATH'};
    if ( $path_var =~ /:\./ ) {
        $VTMBTool->info(" Found Dot in Path Variable");
    }
    else {
        $VTMBTool->info(" Adding Dot in Path Variable");
        $path_var .= ":.";
        $ENV{'PATH'} = $path_var;
    }

    # Setup Project Environment if specified.
    if ( !defined $ENV{'PROJECT'} ) {
        $VTMBTool->error("PROJECT is not set");
    }

    # Use project rtl.rc or disable in ENV set.
    if ( defined $GkConfig{rtlSetupCmd} ) {
        # For testing.  Beta setup may set a $BETA_SOURCE file
        if(defined $ENV{'BETA_SOURCE'}) {
            $GkConfig{'rtlSetupCmd'} = $ENV{'BETA_SOURCE'};
            $VTMBTool->info("Using testenvironment setting: $ENV{'BETA_SOURCE'}");
        }
        else {
            $VTMBTool->info("Setting up environment using $GkConfig{rtlSetupCmd}");
        }
        # Setup Project Specific Environment for tool to work.
        $cmd = "/bin/csh -f -c 'setenv SKIP_NEWGRP 1;$GkConfig{rtlSetupCmd}; printenv'";
        if ( $VTMBTool->run( $cmd, \@cmd_results ) == 0 ) {
            foreach (@cmd_results) {
                chomp;
                ( $var, $val ) = split /\s*=\s*/, $_, 2 if ($_ =~ /=/);
                if ( $var and $val ) {

                    #print "$var=$val\n";
                    $var =~ s/^\s+//g;
                    $var =~ s/\s+$//g;
                    $val =~ s/^\s+//g;
                    $val =~ s/\s+$//g;
                    $ENV{$var} = $val;
                }
            }
            $ENV{LISTNAME} = "gk" if (! defined $Models{disable_runreg_links_creation} || ($Models{disable_runreg_links_creation} == 0));
            $ENV{MODEL}    = ".";
            $ENV{IN_GK}    = 1;               ## Jul 30, 2010 - Simha
            $ENV{SITE}     = $ENV{EC_SITE};
            chomp( $ENV{MODEL} );
        }
        else {
            $VTMBTool->error(
"$ENV{'PROJECT'} Source RC Command Failed. Contact GK Integration Script Owner"
            );
        }
    }
    else {
        $VTMBTool->error(
"Project Environment Setup, \$GkConfig{rtlSetupCmd} is not set. Please add this variable to your GkConfig.$ENV{'PROJECT'}.pl or GkConfig.$ENV{'PROJECT'}.$ENV{'GK_CLUSTER'}.pl "
        );
    }

    # Insure HSD setting
    if ( ( !defined $ENV{'GK_HSD'} ) && ( defined $GkConfig{HSD} ) ) {
        $ENV{'GK_HSD'} = $GkConfig{HSD};
    }
# Setup Environment Variables to be referenced in GkUtils.$PROJECT.cfg, things like $MODEL.
# The way model_root is determined is based on repo type, BK, GIT, or none.
#  Setup MODEL
    if ( $GkConfig{version_control_lib} eq "BK" ) {
        $ENV{'MODEL'}     = `bk root`;
        $ENV{'REPO_ROOT'} = $ENV{'MODEL'};
    }
    elsif ( $GkConfig{version_control_lib} eq "Git" ) {
        $ENV{'MODEL'} = `git rev-parse --show-toplevel`;
        $ENV{'MODEL'} = $ENV{'MODEL'};
    }
    else {
        $VTMBTool->error(
            "Repository Type Not Specified! Currently Supported Types are: bk git");
        $VTMBTool->check_errors();
    }

    # Remove potential newline char from $ENV{'MODEL'} and export MODEL_ROOOT_BASE.
    chomp( $ENV{'MODEL'} );
    chomp( $ENV{'MODEL'} );
    $ENV{'MODEL_BASE'} = basename( $ENV{'MODEL'} );

    my $cfg_file;

    # Get the GkUtils Recipe File
    if ( defined $ENV{'GK_UTILS_CFG'} && -e $ENV{'GK_UTILS_CFG'} ) {
        $VTMBTool->info("Using User Specified Configuration File: $ENV{'GK_UTILS_CFG'}");
    }
    else {
        if (
            -e "$ENV{GK_CONFIG_DIR}/GkUtils.$ENV{'GK_CLUSTER'}.$ENV{'GK_BRANCH'}.cfg"
          )
        {

            # Look for Stepping & Cluster & GkEventtype Specific cfg
            $cfg_file =
"$ENV{GK_CONFIG_DIR}/GkUtils.$ENV{'GK_STEP'}.$ENV{'GK_CLUSTER'}.$ENV{'GK_EVENTTYPE'}.cfg";
            $VTMBTool->info(
                "Using Stepping & Cluster Specific Configuration File: $cfg_file");
        }
        elsif ( -e "$ENV{GK_CONFIG_DIR}/GkUtils.$ENV{'GK_STEP'}.$ENV{'GK_CLUSTER'}.cfg" )
        {

            # Look for Stepping & Cluster Specific cfg
            $cfg_file =
              "$ENV{GK_CONFIG_DIR}/GkUtils.$ENV{'GK_STEP'}.$ENV{'GK_CLUSTER'}.cfg";
            $VTMBTool->info(
                "Using Stepping & Cluster Specific Configuration File: $cfg_file");
        }
        elsif ( -e "$ENV{GK_CONFIG_DIR}/GkUtils.$ENV{'GK_CLUSTER'}.cfg" ) {

            # Look for Cluster Specific cfg
            $cfg_file = "$ENV{GK_CONFIG_DIR}/GkUtils.$ENV{'GK_CLUSTER'}.cfg";
            $VTMBTool->info("Using Cluster Specific Configuration File: $cfg_file");
        }
        elsif ( -e "$ENV{GK_CONFIG_DIR}/GkUtils.$ENV{'GK_STEP'}.cfg" ) {

            # Look for Stepping Specific cfg
            $cfg_file = "$ENV{GK_CONFIG_DIR}/GkUtils.$ENV{'GK_STEP'}.cfg";
            $VTMBTool->info("Using Stepping Specific Configuration File: $cfg_file");
        }
        else {

            # Else take Project Specific cfg
            $cfg_file = "$ENV{GK_CONFIG_DIR}/GkUtils.$ENV{'PROJECT'}.cfg";
            $VTMBTool->set( 'QUIET', 0 ) if !$ENV{'DISABLE_QUIET_MODE'};
            $VTMBTool->info("Using Project Specific Configuration File: $cfg_file");
            $VTMBTool->set( 'QUIET', 1 ) if !$ENV{'DISABLE_QUIET_MODE'};
        }

    }

    $ENV{'GK_UTILS_CFG'} = $cfg_file;
    require "$ENV{'GK_UTILS_CFG'}";
    print $cfg_file;

# We have ModelRoot, create the GATEKEEPER directory, check if .gk_save area needs to exists.
    if (
        ( !$print_commands )
        && ( defined $Models{'gk_save'}{ $ENV{'GK_CLUSTER'} }{ $ENV{'GK_EVENTTYPE'} }
            && ( $Models{'gk_save'}{ $ENV{'GK_CLUSTER'} }{ $ENV{'GK_EVENTTYPE'} } == 1 ) )
      )
    {
        $VTMBTool->create_directories("$ENV{'MODEL'}/GATEKEEPER");
        system "touch $ENV{'MODEL'}/GATEKEEPER/.gk_save";
    }

# If Defined, create Clone within a Clone to support Nested Modeling Capability.
# Clone should only be removed or created by default for Mock,Filter, Turnin and Release.
# For Post-Release it should not be removed if it exists, if it doesn't it should be created.
    if ( ( defined $Models{clone_in_clone} ) && ( !$print_commands ) ) {
        $clone_in_clone = 1;
        if (   ( -d "$ENV{'MODEL'}/$Models{clone_in_clone}" )
            && ( $GkEventType ne "POST-RELEASE" ) )
        {
            $VTMBTool->info(
                "Found Existing Clone, removing $ENV{'MODEL'}/$Models{clone_in_clone} ");
            $cmd = "rm -Rf $ENV{'MODEL'}/$Models{clone_in_clone}";
            $VTMBTool->run($cmd);
        }
        else {
            $VTMBTool->info(
"Found Existing Clone, not removing due to POST-RELEASE $ENV{'MODEL'}/$Models{clone_in_clone} "
            );
        }

        if ( !-d "$ENV{'MODEL'}/$Models{clone_in_clone}" ) {
            $VTMBTool->info("Create Hardlinked Clone within this GK area. ");
            $cmd = "bk clone -q -l $ENV{'MODEL'} $ENV{'MODEL'}/$Models{clone_in_clone}";
            if ( $VTMBTool->run( $cmd, \@cmd_results ) == 0 ) {
                $VTMBTool->info(
                    "Clone successfully created at $ENV{'MODEL'}/$Models{clone_in_clone} "
                );

                # Create a NBFeeder Tasks Area within the clone
                $VTMBTool->create_directories(
                    "$ENV{'MODEL'}/$Models{clone_in_clone}/GATEKEEPER/NBFeederTaskJobs");
            }
            else {
                $VTMBTool->error(
"Clone was not successfully created $ENV{'MODEL'}/$Models{clone_in_clone} "
                );
            }
        }
        else {
            $VTMBTool->info("Clone not created");
        }
    }

    # Check to See if a second rtl.rc is required by a particular cluster/stepping.
    if ( defined $GkConfig{Additional_rtlSetupCmd} ) {
        $VTMBTool->info(
            "Setting up environment using 2nd rtl.rc: $GkConfig{Additional_rtlSetupCmd}");

        # Setup Project Specific Environment for tool to work.
        $cmd = "/bin/csh -f -c '$GkConfig{Additional_rtlSetupCmd}; printenv'";
        if ( $VTMBTool->run( $cmd, \@cmd_results ) == 0 ) {
            foreach (@cmd_results) {
                chomp;
                ( $var, $val ) = split /\s*=\s*/, $_, 2;
                if ( $var and $val ) {

                    #print "$var=$val\n";
                    $ENV{$var} = $val;
                }
            }
        }
        else {
            $VTMBTool->error(
                "Invocation for 2nd rtl.rc failed : $GkConfig{Additional_rtlSetupCmd}");
        }
    }

    # Temporary Hack to enable commands to run prior to turnins running.
    if ( defined $Models{pre_turnin_cmds} && ( !$print_commands ) ) {

        # Loop thru the commands and run them.
        foreach my $cmd_idx ( @{ $Models{pre_turnin_cmds} } ) {
            $cmd = $cmd_idx;
            $VTMBTool->info("Running command : $cmd");
            if ( $VTMBTool->run( $cmd, \@cmd_results ) == 0 ) {
                $VTMBTool->info("Invocation Passed for : $cmd");
            }
            else {
                $VTMBTool->error("Invocation failed for : $cmd");
            }
        }
    }

    # Terminate on any errors
    $VTMBTool->check_errors();
}

#----------------------------------------------------------------------------------------
# parse_cmdline()
#   Defines the tool commandline, then parses it.
#----------------------------------------------------------------------------------------
sub parse_cmdline {

    # Display status and set up indentation
    $VTMBTool->indent_msg(0);
    $VTMBTool->info("Parsing command line ...");
    $VTMBTool->indent_msg(2);

    #
    # Define command line arguments specific to this tool
    my %args = ();

    $args{'-stepping'} = {
        ALIAS       => '-s',
        TYPE        => 'string',
        REQUIRED    => 0,
        DESCRIPTION => 'Name of Stepping',
    };
    $args{'-cluster'} = {
        ALIAS       => '-c',
        TYPE        => 'string',
        REQUIRED    => 0,
        DESCRIPTION => 'Name of Cluster',
    };
    $args{'-turnin'} = {
        TYPE     => 'flag',
        REQUIRED => 0,
        DESCRIPTION =>
          'Process a Turnin to Build & Regress the Model in a Working Repository.',
    };
    $args{'-release'} = {
        TYPE     => 'flag',
        REQUIRED => 0,
        DESCRIPTION =>
'Process a single or multiple Turnins to Build & Regress the Model in a Release Area.',
    };
    $args{'-mock'} = {
        TYPE     => 'flag',
        REQUIRED => 0,
        DESCRIPTION =>
          'Process a Turnins to Build & Regress the Model in a Mock Turnin Area.',
    };
    $args{'-filter'} = {
        TYPE     => 'flag',
        REQUIRED => 0,
        DESCRIPTION =>
          'Process a Turnins to Build & Regress the Model in a Filter Build Area.',
    };
    $args{'-post-release'} = {
        TYPE        => 'flag',
        REQUIRED    => 0,
        DESCRIPTION => 'Run Additional Jobs after the Release is completed',
    };
    $args{'-commands'} = {
        TYPE        => 'flag',
        REQUIRED    => 0,
        DESCRIPTION => 'Dump All Commands to the Screen',
    };
    $args{'-recipe_perl'} = {
        TYPE        => 'flag',
        REQUIRED    => 0,
        DESCRIPTION => 'Dump recipe as perl array to the screen',
    };
    $args{'-verbose'} = {
        ALIAS       => '-v',
        TYPE        => 'flag',
        REQUIRED    => 0,
        DESCRIPTION => 'Print detailed information to screen',
    };
    $args{'-stats'} = {
        TYPE        => 'flag',
        REQUIRED    => 0,
        DESCRIPTION => 'Process GK Cradle to Grave Stats from a completed Work Area',
    };
    $args{'-regress_stats'} = {
        TYPE        => 'flag',
        REQUIRED    => 0,
        DESCRIPTION => 'Process GK Regression Stats from a completed Work Area',
    };
    $args{'-proj'} = {
        TYPE        => 'string',
        REQUIRED    => 0,
        DESCRIPTION => 'Set the Project',
    };
    $args{'-pre_build_regress'} = {
        TYPE        => 'flag',
        REQUIRED    => 0,
        DESCRIPTION => 'Process a User Defined Recipe.',
    };
    $args{'-sleep'} = {
        TYPE     => 'integer',
        REQUIRED => 0,
        DESCRIPTION =>
          'Set the Sleep cycle for the script when jobs are submitted to netbatch',
    };
    $args{'-cfg'} = {
        TYPE        => 'string',
        REQUIRED    => 0,
        DESCRIPTION => 'Use a user defined config',
    };
    $args{'-build_only'} = {
        TYPE        => 'flag',
        REQUIRED    => 0,
        DESCRIPTION => 'Only Add Build Jobs. Regressions are disabled.',
    };
    $args{'-pid'} = {
        TYPE        => 'string',
        REQUIRED    => 0,
        DESCRIPTION => 'Specify Process ID',
    };
    $args{'-disable_perms'} = {
        ALIAS       => '-dp',
        TYPE        => 'flag',
        REQUIRED    => 0,
        DESCRIPTION => 'Disable Any Chmod or Chgrp operations',
    };
    $args{'-duts'} = {
        TYPE        => 'string',
        REQUIRED    => 0,
        DESCRIPTION => 'List of Duts to keep in build/regress jobs',
    };
    $args{'-jobs'} = {
        TYPE        => 'string',
        REQUIRED    => 0,
        DESCRIPTION => 'List of Jobs to keep in build/regress jobs',
    };
    $args{'-dev'} = {
        TYPE        => 'flag',
        REQUIRED    => 0,
        DESCRIPTION => 'GK DEV Mode of operation',
    };

    # Define the tool help description
    my $desc =
'Tool process turnins in Working Repository, or release area when spawned by GateKeeper';

    # Define tool usage examples
    my @examples = ();
    push @examples, 'Process Turnin',
      $VTMBTool->get('NAME') . ' -s <stepping> -c <cluster> -turnin';
    push @examples, 'Release Turnin',
      $VTMBTool->get('NAME') . ' -s <stepping> -c <cluster> -release';
    push @examples, 'Mock    Turnin',
      $VTMBTool->get('NAME') . ' -s <stepping> -c <cluster> -mock';
    push @examples, 'Filter Build',
      $VTMBTool->get('NAME') . ' -s <stepping> -c <cluster> -filter';

    # Use common tool arguments (-help, -debug, etc.)
    my $common = 1;

    # Initialize command line object or die
    $VTMBCmdline = new VTMBCmdline(
        TOOLOBJ     => $VTMBTool,
        ARGUMENTS   => \%args,
        DESCRIPTION => $desc,
        EXAMPLES    => \@examples,
        USE_COMMON  => $common,
      )
      or $VTMBTool->fatal(
        'Error initializing VTMBCmdline object.  Report this bug to Chancellor Archie.');

    # Parse the command line and terminate on any Errors
    $VTMBCmdline->parse();
    $VTMBTool->check_errors();

    # Set Environment Variables with commandline option if specified.
    # Define this tool's required environment variables
    if ( defined $VTMBCmdline->value('-turnin') ) {
        $ENV{'GK_EVENTTYPE'} = "turnin";
    }
    if ( defined $VTMBCmdline->value('-release') ) {
        $ENV{'GK_EVENTTYPE'} = "release";
    }
    if ( defined $VTMBCmdline->value('-post-release') ) {
        $ENV{'GK_EVENTTYPE'} = "post-release";
    }
    if ( defined $VTMBCmdline->value('-mock') ) {
        $ENV{'GK_EVENTTYPE'} = "mock";
    }
    if ( defined $VTMBCmdline->value('-filter') ) {
        $ENV{'GK_EVENTTYPE'} = "filter";
    }
    if ( $VTMBCmdline->value('-stepping') ) {
        $ENV{'GK_STEP'}     = $VTMBCmdline->value('-stepping');
        $ENV{'GK_STEPPING'} = $VTMBCmdline->value('-stepping');
    }
    if ( $VTMBCmdline->value('-cluster') ) {
        $ENV{'GK_CLUSTER'} = $VTMBCmdline->value('-cluster');
    }
    if ( $VTMBCmdline->value('-commands') ) {
        $ENV{'GK_PRINT_COMMANDS'} = $VTMBCmdline->value('-commands');
    }
    if ( $VTMBCmdline->value('-stats') ) {
        $ENV{'GK_PRINT_STATS'} = $VTMBCmdline->value('-stats');
    }
    if ( $VTMBCmdline->value('-recipe_perl') ) {
        $ENV{'GK_RECIPE_PERL'} = $VTMBCmdline->value('-recipe_perl');
    }
    if ( $VTMBCmdline->value('-proj') ) {
        $ENV{'PROJECT'} = $VTMBCmdline->value('-proj');
    }
    if ( $VTMBCmdline->value('-verbose') ) {
        $ENV{'DISABLE_QUIET_MODE'} = 1;
    }
    if ( $VTMBCmdline->value('-sleep') ) {
        $sleep_cycle = $VTMBCmdline->value('-sleep');
    }
    else {
        $sleep_cycle = 600;
    }

    # Create a special recipe for test purposes
    if ( defined $VTMBCmdline->value('-cfg') ) {
        $ENV{'GK_UTILS_CFG'} = $VTMBCmdline->value('-cfg');
    }

    if ( defined $VTMBCmdline->value('-pre_build_regress') ) {
        $PreBuildRegress = 1;
        $ENV{'PRE_BUILD_REGRESS'} = 1;
    }

    #Capitalized Version of Setting, needed to access Configuration HASH.
    $GkEventType = uc( $ENV{'GK_EVENTTYPE'} );

    # Confirm that some valid GkEventtype was specified if not die.
    if (
        ( !defined $ENV{'GK_EVENTTYPE'} )
        || ( defined $GkEventType ) && ( ( $GkEventType ne "MOCK" )
            && ( $GkEventType ne "TURNIN" )
            && ( $GkEventType ne "FILTER" )
            && ( $GkEventType ne "RELEASE" )
            && ( $GkEventType ne "DROP" )
            && ( $GkEventType ne "POST-RELEASE" ) )
      )
    {
        $VTMBTool->error("No Valid GK_EVENTTYPE was specified thru cmdline or ENV");
        $VTMBTool->error(
"Please set GK_EVENTTYPE turnin or mock or release or post-release or filter, or user -help to see cmdline arguements."
        );
        $VTMBTool->check_errors();
    }

    # Check for Illegal Conditions and issue error if found.
    if (
        $ENV{'GK_EVENTTYPE'} eq "turnin"
        && (   ( defined $VTMBCmdline->value('-release') )
            || ( defined $VTMBCmdline->value('-filter') )
            || ( defined $VTMBCmdline->value('-mock') ) )
      )
    {
        $VTMBTool->error(
            "Illegal Condition GK_EVENTTYPE == turnin and commandline options differs");
    }
    elsif (
        $ENV{'GK_EVENTTYPE'} eq "release"
        && (   ( defined $VTMBCmdline->value('-turnin') )
            || ( defined $VTMBCmdline->value('-filter') )
            || ( defined $VTMBCmdline->value('-mock') ) )
      )
    {
        $VTMBTool->error(
            "Illegal Condition GK_EVENTTPE == release and commandline options differs");
    }
    elsif (
        $ENV{'GK_EVENTTYPE'} eq "filter"
        && (   ( defined $VTMBCmdline->value('-turnin') )
            || ( defined $VTMBCmdline->value('-release') )
            || ( defined $VTMBCmdline->value('-mock') ) )
      )
    {
        $VTMBTool->error(
            "Illegal Condition GK_EVENTTPE == filter and commandline options differs");
    }
    elsif (
        $ENV{'GK_EVENTTYPE'} eq "mock"
        && (   ( defined $VTMBCmdline->value('-turnin') )
            || ( defined $VTMBCmdline->value('-release') )
            || ( defined $VTMBCmdline->value('-filter') ) )
      )
    {
        $VTMBTool->error(
            "Illegal Condition GK_EVENTTPE == mock and commandline options differs");
    }

    $print_commands =
      (      defined $ENV{'GK_PRINT_COMMANDS'}
          || ( defined $ENV{'GK_RECIPE_PERL'} && $ENV{'GK_RECIPE_PERL'} )
          || defined $ENV{'GK_PRINT_STATS'} ) ? 1 : 0;

    # Disable Permission and Group overrides from GkUtils CFG
    if ( $VTMBCmdline->value('-disable_perms') ) {
        $ENV{'GK_DISABLE_PERMS'} = 1;
    }

    # List of Duts to process
    if ( defined $VTMBCmdline->value('-duts') ) {
        $DisableTaskCreation = 1;
        $ENV{'GK_REDUCED_DUTS'} = $VTMBCmdline->value('-duts');
    }

    # List of Duts to process
    if ( defined $VTMBCmdline->value('-jobs') ) {
        $DisableTaskCreation = 1;
        $ENV{'GK_REDUCED_JOBS'} = $VTMBCmdline->value('-jobs');
    }

    # Support for DEV mode switch, from GK and commandline.
    if ( defined $VTMBCmdline->value('-dev') ) {
        $ENV{'GK_DEV'} = 1;
        $VTMBTool->info("Setting DEV Mode");
    }

    # Display arguments used and Terminate on any errors
    $VTMBTool->info( "Command line used: " . $VTMBCmdline->identify() );
    $VTMBTool->check_errors();
}

#----------------------------------------------------------------------------------------
# check_environment()
#   Checks the environment
#----------------------------------------------------------------------------------------
sub check_environment {

    # Display status and set up indentation
    $VTMBTool->indent_msg(0);
    $VTMBTool->info("Checking environment ...");
    $VTMBTool->indent_msg(2);

    # Define this tool's required environment variables
    my @req_vars = (
        'GK_CLUSTER',             # GateKeeper Cluster Setting
        'GK_STEP',                # GateKeeper Stepping Setting
        'GK_STEPPING',            # GateKeeper Stepping Setting
        'GK_EVENTTYPE',           # GateKeeper Event Type
        'MODEL',                  # Model Root
        'USER',                   # USER who is running the process
        'GK_FEEDER_WORK_AREA',    # GK NBFeeder Work Area
        'MY_PID',                 # This Scripts Process ID
        'GK_UTILS_VER',           # Version of GK Utils being run.
        'GK_UTILS_CFG',           # GK_UTILS_CFG Variable
    );

    #Define this tools optional environment variables
    my @opt_vars = (
        'PATH',                         # Path Variable
        'CAMA_MODEL_CACHING_DISK',      # Path to CAMA Model Caching Disk
        'TOOLCONFIG_OVERRIDE',          # Tool Config Override Setting
        'FEEDER_WORK_AREA',             # Project NBFeeder Work Area
        'SITE',                         # Site
        'NBPOOL',                       # Netbatch Pool
        'NBCLASS',                      # Netbatch Class
        'NBQSLOT',                      # Netbatch Qslot
        'GK_NBPOOL',                    # GateKeeper Netbatch Pool
        'GK_NBCLASS',                   # GateKeeper Netbatch Class
        'GK_NBQSLOT',                   # GateKeeper Netbatch Qslot
        'GK_MOCK_NBPOOL',               # GateKeeper Netbatch Pool
        'GK_MOCK_NBCLASS',              # GateKeeper Netbatch Class
        'GK_MOCK_NBQSLOT',              # GateKeeper Netbatch Qslot
        'GK_MOCK_PRIORITY_QSLOT',       # GateKeeper Netbatch Qslot
        'GK_MOCK_NOSUSPEND_CLASS',      # GateKeeper Netbatch Qslot
        'GK_EVENT',                     # GateKeeper Event Type
        'GK_HSD',                       # GateKeeper HSD Database
        'GK_INTEGRATION_PATH',          # GateKeeper Integration Path
        'GK_PRINT_COMMANDS',            # Gatekeeper Print Commands
        'GK_RECIPE_PERL',               #
        'GK_MOCKPRIORITY',              # GateKeeper Mock Priority
        'GK_PRIORITY',                  # GateKeeper Priority
        'GK_LEVEL1',                    # GateKeeper Level1
        'GK_NBCLASS',                   # GateKeeper NB Class
        'GK_FILES_CHANGED',             # GateKeeper Files Changed
        'GK_DEV',                       # GateKeeper DEV Setting
        'GK_USER',                      # GateKeeper User
        'GK_TURNIN_ID',                 # GateKeeper Turnin ID
        'GK_TURNIN_IDS',                # GateKeeper Turnin IDS Contained within a bundle.
        'GK_RELEASE_ID',                # GateKeeper Release IDS
        'GK_ATTEMPTS',                  # GateKeeper Attempts
        'GK_BUNDLE_SIZE',               # GateKeeper Bundle Size
        'GK_HOST',                      # GateKeeper HOST
        'GK_OVERRIDE_PATH',             # GK Path Override
        'GK_DISABLE_QC',                # GK Disable QC Check
        'GK_DISABLE_RTLRC',             # GK Disable rtl.rc
        'GK_DISABLE_DISK_SPACE_CHECK',  # Disable Disk Space Checks
        'GK_ADMIN_EMAIL_LIST',          # Gatekeeper Adminstrator Email List
        'GK_MOCK_REGRESS_SAVE',         # GateKeeper Mock Turnin Save Regressions
        'GK_MOCK_SIMREGRESS_ADD'
        ,                     # GateKeeper Mock Turnin Additional Options to simregress
        'SETUP_ON_64BITS',    # Setup on 64 bit.
        'DISPLAY',            # DISPLAY
        'GK_MOCK_CLEAN',      # Clean parts of the model for MockTurnin
        'RTLMODELS',          # RTLMODELS which should be set by rtl.rc
        'GK_REDUCED_DUTS'
        ,    # GK Reduced Duts to direct MockTurnin or Filter to prune job tree.
        'GK_REDUCED_JOBS'
        ,    # GK Reduced Jobs to direct MockTurnin or Filter to prune job tree.
        'GK_REDUCED_STAGES'
        ,    # GK Reduced Stages to direct MockTurnin or Filter to prune job tree.
        'GK_DISABLE_RTLRC',    # Disable sourcing of rtl.rc
        'ACE_PROJECT',         # ACE Project Setting
        'GK_CENTRAL_REPO',     # GK Reposistory
                               #'NB_POOLS',                # Setting for NB_POOLS
        '__NBFEEDER_LOG_HISTORY_SIZE',
    );

    # Check the environment and save a record of what has been set.
    @envVars = $VTMBTool->check_environment( \@req_vars, \@opt_vars );

    # There are some environment variables which should never be set in a GK process.
    # If set, unsetenv them.
    if ( defined $ENV{'SETUP_ON_64BITS'} ) {
        $VTMBTool->info(
            "Environment Variable \$SETUP_ON_64BITS was set. It has been undefined.");
        delete $ENV{'SETUP_ON_64BITS'};
    }
    if ( defined $ENV{'DISPLAY'} ) {
        $VTMBTool->info("Environment Variable \$DISPLAY was set. It has been undefined.");
        delete $ENV{'DISPLAY'};
    }

    # Run SkipFilter checks only in filter stage
            if ($ENV{'GK_EVENTTYPE'} eq "filter" && !$ENV{GK_DISABLE_QC} )
    {
        if ( -e "$Bin/SmartFilter/skip_filter.pl" && $Models{smart_filter_on} == 1) {
            $VTMBTool->info("Running SkipFilter Check");
            my $cmd =
"$Bin/SmartFilter/skip_filter.pl >& $ENV{MODEL}/GATEKEEPER/skip_filter.log";
            my @cmd_results;
            if ( $VTMBTool->run( $cmd, \@cmd_results ) == 19 ) {

                $VTMBTool->info(
"Your changes qualify for skipping filter, see $ENV{MODEL}/GATEKEEPER/skip_filter.log"
                );
                if (!$PreBuildRegress) {
                  my @sf_mails = @{$Models{sf_notification_mail}};
                  my $sf_email = join (',',@sf_mails);
                  $VTMBTool->info("Now sending mail to the user");
                  $VTMBTool->run("$Bin/SmartFilter/sf_sendmail.pl $sf_email");
                }
                exit 0;

            }
            else {
                $VTMBTool->info(
"Your changes do not qualify for skipping filter, see $ENV{MODEL}/GATEKEEPER/skip_filter.log"
                );
            }
        }

        else {
            $VTMBTool->info(
"Failed to locate SkipFilter Script or SmartFilter is Disabled"
            );
        }
    }

   # Enable some pre-mockturnin commands - This is a temporary hack to GK update is ready.
    if (   defined $Models{pre_mock_turnin_cmds}
        && ( !$print_commands )
        && ( $ENV{'GK_EVENTTYPE'} eq "mock" ) )
    {
        my ( $cmd, $cmd_idx, @cmd_results );
        $VTMBTool->info("Pre Mock Turnin Commands Defined. ");

        # Loop thru the commands and run them.
        foreach my $cmd_idx ( @{ $Models{pre_mock_turnin_cmds} } ) {
            $cmd = $cmd_idx;
            $VTMBTool->info("Running command : $cmd");
            if ( $VTMBTool->run( $cmd, \@cmd_results ) == 0 ) {
                $VTMBTool->info(" Pre Mock Turnin CMD Invocation Passed for : $cmd");
                foreach my $cmd_result_idx (@cmd_results) {
                    $VTMBTool->warning("PASSED : $cmd_result_idx  ");
                }
            }
            else {
                $VTMBTool->warning(" Post Turnin CMD Invocation failed for : $cmd");

                foreach my $cmd_result_idx (@cmd_results) {
                    $VTMBTool->warning("Failure : $cmd_result_idx  ");
                }
            }
        }
    }

    # Terminate if errors encountered
    $VTMBTool->check_errors();
}

#-------------------------------------------------------------------------------
# init_log()
#    Initializes the log file by creating a global object
#-------------------------------------------------------------------------------
sub init_log {

    # Display status and set up indentation
    $VTMBTool->indent_msg(0);
    $VTMBTool->info("Starting Log File");
    $VTMBTool->indent_msg(2);

    $print_commands =
      (      defined $ENV{'GK_PRINT_COMMANDS'}
          || ( defined $ENV{'GK_RECIPE_PERL'} && $ENV{'GK_RECIPE_PERL'} )
          || defined $ENV{'GK_PRINT_STATS'} ) ? 1 : 0;

    ## If it Doesn't exist, create GATEKEEPER directory which will contain log file.
    $VTMBTool->create_directories( $VTMBObj->get('MODEL') . "/GATEKEEPER" );
    if ( !$print_commands ) {

        # Initialize log file object or die
        if ($PreBuildRegress) {
            $VTMBLog = new VTMBLog(
                SUPPRESS_RESULTS => 1,
                TOOLOBJ          => $VTMBTool,
                PATH => $VTMBObj->get('MODEL') . "/GATEKEEPER/pre_build_regress.log",
              )
              or $VTMBTool->fatal(
                'Error initializing TCGLog object.  Report this bug to DA.');
        }
        else {
            $VTMBLog = new VTMBLog(
                SUPPRESS_RESULTS => 1,
                TOOLOBJ          => $VTMBTool,
                PATH             => $VTMBObj->get('MODEL')
                  . "/GATEKEEPER/"
                  . $VTMBTool->get('NAME') . ".log",
              )
              or $VTMBTool->fatal(
                'Error initializing TCGLog object.  Report this bug to DA.');
        }

        $VTMBTool->info( "Log file created: " . $VTMBLog->get('PATH') );

        # Output before the log was created.
        if ( defined $VTMBTool->{STDOUT_BEFORE_LOG} ) {
            my @pre_log = split( /:space:/, $VTMBTool->{STDOUT_BEFORE_LOG} );
            foreach my $pre_log_line (@pre_log) {
                chomp($pre_log_line);
                $pre_log_line =~ s/gk-utils -I-//g;
                $VTMBTool->info("$pre_log_line");
            }
        }

        # Output to log since it was displayed before log file was created
        $VTMBTool->log( "Command line used: $0 " . $VTMBCmdline->identify() );
        $VTMBTool->log("Working directory = $workdir");
        foreach (@envVars) {
            $VTMBTool->log( '$' . $_ );
        }

        # Create Report file name
        $job_report = $VTMBObj->get('MODEL') . "/GATEKEEPER" . "/gk_report.txt";
        my $report_csv = $VTMBObj->get('MODEL') . "/GATEKEEPER" . "/gk_report.csv";
        if ( -e $job_report ) {
            $VTMBTool->movefile( $job_report, "$job_report.bak" );
        }
        if (-e $report_csv) {
           $VTMBTool->movefile( $report_csv, "$report_csv.bak" );
        }

# Save a Copy of the GK Recipe in MODEL/GATEKEEPER, print instructions on reproducibility.
        if (   ( $ENV{'GK_EVENTTYPE'} eq "filter" )
            || ( $ENV{'GK_EVENTTYPE'} eq "turnin" )
            || ( $ENV{'GK_EVENTTYPE'} eq "release" ) )
        {
            $VTMBTool->copyfile( $ENV{'GK_UTILS_CFG'},
                "$ENV{'MODEL'}/GATEKEEPER/GkUtils.$ENV{'GK_STEP'}.$ENV{'GK_CLUSTER'}.cfg"
            );
            $VTMBTool->blank();
            $VTMBTool->info(" To Reproduce this invocation");
            $VTMBTool->info(" git clone $ENV{'MODEL'}");
            $VTMBTool->info(
" setenv GK_UTILS_CFG $ENV{'MODEL'}/GATEKEEPER/GkUtils.$ENV{'GK_STEP'}.$ENV{'GK_CLUSTER'}.cfg"
            );
            $VTMBTool->info(
                " turnin -s $ENV{'GK_STEP'} -c $ENV{'GK_CLUSTER'} -mock -local");
            $VTMBTool->blank();
        }

        # Terminate on errors
        $VTMBTool->check_errors();
    }
    $VTMBTool->indent_msg(0);
}

sub get_feeder_host {
    # Get the feeder host name base on ION machine availability

    my $Models_input = shift;
    my %Models       = %$Models_input;    ## no critic (ProhibitReusedNames)
    $Models{nbflow_bin} = "/nfs/site/gen/adm/netbatch/nbfeeder/install/$ENV{'NBFEEDER_VERSION'}/bin";

    my $resource_pool = $Models{resources}{$ENV{SITE}};
    my $nbflm_server = $Models{nbflm_servers}{$ENV{SITE}};

    my $cmd_root = &catfile($Models{nbflow_bin}, "nbstatus");
    my @cmd = ($cmd_root, "workstations",
               "--target", "$nbflm_server",
               "--fields", "\"fullhost,Load,status\"",
               "--sort-by", "Load",
               "--format", "script",
               "\"resourcegroups=~\'$resource_pool\'\"");
    my $machine_cmd = join (' ', @cmd);
    $VTMBTool->info("executing command: $machine_cmd");
    my @stdout;
    $VTMBTool->run($machine_cmd, \@stdout);

    if (!@stdout) {
        $VTMBTool->error("Error getting a machine to host feeder.");
        $VTMBTool->error("Check with your HWKC : " . join(' ', @cmd));
        $VTMBTool->check_errors()
    } else {
#        my $output = $stdout[0];

        foreach my $out (@stdout)
        {
            my ($host, $load, $status) = split /,/, $out;
            if ($status=~/Accepting/i)
            {
                $VTMBTool->info("Using machine:$host");
                return $host;
            }
            else
            {
                $VTMBTool->info("Skipping machine:$host. Status: $status");
            }
        }
        $VTMBTool->error("Error getting a machine to host feeder");
        $VTMBTool->error("Check with your HWKC: " . join(' ', @cmd));
        return $VTMBTool->check_errors();
    }
}

sub job_run_info {

    # Display status and set up indentation
    $VTMBTool->indent_msg(0);
    $VTMBTool->info("Setting Up Job Run Information");
    $VTMBTool->indent_msg(2);

    # CAMA Unregistration
    my ( $cama_unreg, @cama_unreg_output );

    # Determine Job ID Type, Location, and other information.
    my ( $WARD, $job_type, $task_prefix, $task_tag, $run_num );
    my ( $dir_name, $dir_num );
    $WARD = $workdir;

# Set Print_commands flag which is used to disable some stages because this is not a gkutils invocation with real work.
    $print_commands =
      (      defined $ENV{'GK_PRINT_COMMANDS'}
          || defined $ENV{'GK_RECIPE_PERL'}
          || defined $ENV{'GK_PRINT_STATS'}
          || defined $ENV{'GK_DEPENDENCY_GRAPH'} ) ? 1 : 0;

    # Set a real PID only if print_commands is not set.
    if ($print_commands) {
        $ENV{'MY_PID'} =
          0; # For Print Commands invocation, force a PID, this is for compare_recipe.csh.
    }
    else {
        $ENV{'MY_PID'} = $$;
    }

	# Method that will check disk space only if it is not being checked in quickbuild.real
	if(not defined $ENV{DUT_SPACE_CHECK} ) {
        &disk_space_check();
    }

#    # Check if enough Disk exists.-Commenting the below- seperate method call
#    my $required_size =
#        $ENV{'GK_EVENTTYPE'} eq "post-release"
#      ? $Models{model_size}{ $ENV{'GK_CLUSTER'} } / 3
#      : $Models{model_size}{ $ENV{'GK_CLUSTER'} };    # rough approximation
#
#    unless ( $print_commands
#        || $VTMBTool->free_disk_space( $ENV{'MODEL'}, $required_size ) )
#	  {
#        if ( !defined $ENV{'GK_DISABLE_DISK_SPACE_CHECK'} ) {
#            $VTMBTool->error(
#"Less than the required ${required_size}GB's of Free Space Exists to build $ENV{'GK_CLUSTER'} exists on this disk."
#            );
#            $VTMBTool->error(" Please Clean up this Disks.");
#            $VTMBTool->error(
#                "  To turnin off this check: setenv GK_DISABLE_DISK_SPACE_CHECK 1");
#        }
#        else {
#            $VTMBTool->warning(
#"Less than the required ${required_size}GB's of Free Space Exists to build $ENV{'GK_CLUSTER'}"
#            );
#            $VTMBTool->warning(" You have chosen to bypass this message.");
#            $VTMBTool->warning("   Jobs could fail unexpectedly.");
#            $VTMBTool->warning(
#                "     Proceed at your own risk and consider yourself warned.");
#        }
#    }

    #NBFEEDER Work Area Override for GKuser by site. verify the area exists.
    if ( defined $Models{feeder_ward}{ $ENV{SITE} }{ $ENV{USER} } ) {
        $ENV{'GK_FEEDER_WORK_AREA'} = $Models{feeder_ward}{ $ENV{'SITE'} }{ $ENV{USER} };
        $VTMBTool->create_directories( $ENV{'GK_FEEDER_WORK_AREA'} );
        $VTMBTool->info(
"GK Feeder WARD override based on Site($ENV{SITE}),User($ENV{USER}) Setting = $ENV{GK_FEEDER_WORK_AREA}"
        );

        if ( defined $Models{feeder_name}{ $ENV{SITE} }{ $ENV{USER} } ) {
            $ENV{GK_FEEDER_NAME} = $Models{feeder_name}{ $ENV{SITE} }{ $ENV{USER} };
            $VTMBTool->info(
"GK Feeder NAME override based on Site($ENV{SITE}),User($ENV{USER}) Setting = $ENV{GK_FEEDER_NAME}"
            );
        }
    }
    elsif ( defined $Models{feeder_ward}{ $ENV{USER} } ) {

        # Determine if there are additional Overrides Exist at the User Level.
        if ( ref $Models{feeder_ward}{ $ENV{USER} } eq '' ) {

            # This key points to a value, that is not a reference
            $ENV{'GK_FEEDER_WORK_AREA'} = $Models{feeder_ward}{ $ENV{USER} };
            $VTMBTool->info(
"GK Feeder WARD override based on User($ENV{USER}) Setting = $ENV{GK_FEEDER_WORK_AREA}"
            );

            if ( ( defined $Models{feeder_name}{ $ENV{USER} } )
                && !( ref $Models{feeder_name}{ $ENV{USER} } ) )
            {
                $ENV{GK_FEEDER_NAME} = $Models{feeder_name}{ $ENV{USER} };
                $VTMBTool->info(
"GK Feeder NAME override based on User($ENV{USER}) Setting = $ENV{GK_FEEDER_NAME}"
                );
            }
        }
        elsif ( ref $Models{feeder_ward}{ $ENV{USER} } eq 'HASH' ) {

            # This key points to a Hash Reference.
            # The Hash Reference can override by Cluster
            # The Cluster can contain a
            if ( defined $Models{feeder_ward}{ $ENV{USER} }{ $ENV{'GK_CLUSTER'} } ) {
                if ( ref $Models{feeder_ward}{ $ENV{USER} }{ $ENV{'GK_CLUSTER'} } eq '' )
                {
                    $ENV{'GK_FEEDER_WORK_AREA'} =
                      $Models{feeder_ward}{ $ENV{USER} }{ $ENV{'GK_CLUSTER'} };
                    $VTMBTool->info(
"GK Feeder WARD override based on User($ENV{USER}),Cluster($ENV{GK_CLUSTER}) Setting = $ENV{GK_FEEDER_WORK_AREA}"
                    );

                    if (
                        (
                            defined $Models{feeder_name}{ $ENV{USER} }{ $ENV{GK_CLUSTER} }
                        )
                        && !( ref $Models{feeder_name}{ $ENV{USER} }{ $ENV{GK_CLUSTER} } )
                      )
                    {
                        $ENV{GK_FEEDER_NAME} =
                          $Models{feeder_name}{ $ENV{USER} }{ $ENV{GK_CLUSTER} };
                        $VTMBTool->info(
"GK Feeder NAME override based on User($ENV{USER}),Cluster($ENV{GK_CLUSTER}) Setting = $ENV{GK_FEEDER_NAME}"
                        );
                    }
                }
                elsif (
                    ref $Models{feeder_ward}{ $ENV{USER} }{ $ENV{'GK_CLUSTER'} } eq
                    'HASH' )
                {

# Determine the Extent of this hash.
#    The override can be by GK EventType.
#    There can also be a default override so all Eventtypes do not need to be fully expanded.
                    if (
                        defined $Models{feeder_ward}{ $ENV{USER} }{ $ENV{'GK_CLUSTER'} }
                        {$GkEventType} )
                    {
                        $ENV{'GK_FEEDER_WORK_AREA'} =
                          $Models{feeder_ward}{ $ENV{USER} }{ $ENV{'GK_CLUSTER'} }
                          {$GkEventType};
                        $VTMBTool->info(
"GK Feeder WARD override based on User($ENV{USER}),Cluster($ENV{GK_CLUSTER}),Event(${GkEventType}) Setting = $ENV{GK_FEEDER_WORK_AREA}"
                        );

                        if (
                            defined $Models{feeder_name}{ $ENV{USER} }{ $ENV{GK_CLUSTER} }
                            {$GkEventType} )
                        {
                            $ENV{GK_FEEDER_NAME} =
                              $Models{feeder_name}{ $ENV{USER} }{ $ENV{GK_CLUSTER} }
                              {$GkEventType};
                            $VTMBTool->info(
"GK Feeder NAME override based on User($ENV{USER}),Cluster($ENV{GK_CLUSTER}),Event(${GkEventType}) Setting = $ENV{GK_FEEDER_NAME}"
                            );
                        }
                    }
                    elsif (
                        defined $Models{feeder_ward}{ $ENV{USER} }{ $ENV{'GK_CLUSTER'} }
                        {'default'} )
                    {
                        $ENV{'GK_FEEDER_WORK_AREA'} =
                          $Models{feeder_ward}{ $ENV{USER} }{ $ENV{'GK_CLUSTER'} }
                          {'default'};
                        $VTMBTool->info(
"GK Feeder WARD override based on User($ENV{USER}),Cluster($ENV{GK_CLUSTER}),Event(default) Setting = $ENV{GK_FEEDER_WORK_AREA}"
                        );

                        if (
                            defined $Models{feeder_name}{ $ENV{USER} }{ $ENV{GK_CLUSTER} }
                            {default} )
                        {
                            $ENV{GK_FEEDER_NAME} =
                              $Models{feeder_name}{ $ENV{USER} }{ $ENV{GK_CLUSTER} }
                              {default};
                            $VTMBTool->info(
"GK Feeder NAME override based on User($ENV{USER}),Cluster($ENV{GK_CLUSTER}),Event(default) Setting = $ENV{GK_FEEDER_NAME}"
                            );
                        }
                    }
                    else {
                        $VTMBTool->error(
"GK Feeder WARD override based on Cluster = $ENV{'GK_CLUSTER'} is not properly defined"
                        );
                        $VTMBTool->check_errors();
                    }
                }
                else {
                    $VTMBTool->error(
"GK Feeder WARD override based on Cluster = $ENV{'GK_CLUSTER'} is not properly defined"
                    );
                    $VTMBTool->check_errors();
                }
            }
            elsif ( defined $Models{feeder_ward}{ $ENV{USER} }{'default'} ) {
                $ENV{'GK_FEEDER_WORK_AREA'} =
                  $Models{feeder_ward}{ $ENV{USER} }{'default'};
                $VTMBTool->info(
"GK Feeder WARD override based on User($ENV{USER}),Cluster(default) Setting = $ENV{GK_FEEDER_WORK_AREA}"
                );

                if ( defined $Models{feeder_name}{ $ENV{USER} }{default} ) {
                    $ENV{GK_FEEDER_NAME} = $Models{feeder_name}{ $ENV{USER} }{default};
                    $VTMBTool->info(
"GK Feeder NAME override based on User($ENV{USER}),Cluster(default) Setting = $ENV{GK_FEEDER_NAME}"
                    );
                }
            }
            else {
                $VTMBTool->error(
"GK Feeder WARD override based on User($ENV{USER}) is not properly defined"
                );
                $VTMBTool->check_errors();
            }
        }
        else {
            $VTMBTool->info(
                "Unsupported type declared for GK Feeder WARD override based on User");
        }
        $VTMBTool->create_directories( $ENV{'GK_FEEDER_WORK_AREA'} );
    }

    #NBFEEDER Work Area Override for Mock Turnin at different site
    elsif ( defined $Models{feeder_ward}{ $ENV{'SITE'} }{$GkEventType} ) {
        $ENV{'GK_FEEDER_WORK_AREA'} = $Models{feeder_ward}{ $ENV{'SITE'} }{$GkEventType};
        $VTMBTool->info(
"GK Feeder WARD override based on Site($ENV{SITE}),Event(${GkEventType}) Setting = $ENV{GK_FEEDER_WORK_AREA}"
        );

        if ( defined $Models{feeder_name}{ $ENV{SITE} }{$GkEventType} ) {
            $ENV{GK_FEEDER_NAME} = $Models{feeder_name}{ $ENV{SITE} }{$GkEventType};
            $VTMBTool->info(
"GK Feeder NAME override based on Site($ENV{SITE}),Event(${GkEventType}) Setting = $ENV{GK_FEEDER_NAME}"
            );
        }

    # For Mock Turnin, the first person to run it creates the Root level FEEDER Work area.
        if ( ( !-d $ENV{'GK_FEEDER_WORK_AREA'} ) && ( $GkEventType eq "MOCK" ) ) {
            $VTMBTool->create_directories( $ENV{'GK_FEEDER_WORK_AREA'} );

            # This area will be used by everyone, chmod group permissions.
            chmod 0770, $ENV{'GK_FEEDER_WORK_AREA'};
        }
    }

    #NBFEEDER Work Area Override for Mock Turnin. Verify the area exists.
    elsif ( defined $Models{feeder_ward}{$GkEventType} ) {
        $ENV{'GK_FEEDER_WORK_AREA'} = $Models{feeder_ward}{$GkEventType};
        $VTMBTool->info(
"GK Feeder WARD override based on Event(${GkEventType}) Setting = $ENV{GK_FEEDER_WORK_AREA}"
        );

        if ( defined $Models{feeder_name}{$GkEventType} ) {
            $ENV{GK_FEEDER_NAME} = $Models{feeder_name}{$GkEventType};
            $VTMBTool->info(
"GK Feeder NAME override based on Event(${GkEventType}) Setting = $ENV{GK_FEEDER_NAME}"
            );
        }

    # For Mock Turnin, the first person to run it creates the Root level FEEDER Work area.
        if ( ( !-d $ENV{'GK_FEEDER_WORK_AREA'} ) && ( $GkEventType eq "MOCK" ) ) {
            $VTMBTool->create_directories( $ENV{'GK_FEEDER_WORK_AREA'} );

            # This area will be used by everyone, chmod group permissions.
            chmod 0770, $ENV{'GK_FEEDER_WORK_AREA'};
        }
    }

    # If no override is specified, use existing variable.
    else {
        $ENV{'GK_FEEDER_WORK_AREA'} = $ENV{'FEEDER_WORK_AREA'};
        $VTMBTool->info("Default GK Feeder WARD Setting = $ENV{GK_FEEDER_WORK_AREA}");
    }

    #Verify the Feeder area exists.
    if ( !-d $ENV{'GK_FEEDER_WORK_AREA'} ) {
        $VTMBTool->error(
            "Specified NB FEEDER WORK AREA $ENV{'GK_FEEDER_WORK_AREA'} does not exist.");
    }
    else {
        $VTMBTool->info(
            "Specified NB FEEDER WORK AREA $ENV{'GK_FEEDER_WORK_AREA'} exist.");
    }

    if ( !$ENV{GK_FEEDER_NAME} ) {
        $VTMBTool->info("Default GK Feeder NAME Setting = Generated by nbfeeder");
    }

    #NBFEEDER Properties File
    if ( defined $Models{feeder_properties_file} ) {
        $ENV{'GK_FEEDER_PROPERTIES_FILE'} = $Models{feeder_properties_file};
    }

    #NBFEEDER Admin User
    if ( defined $Models{feeder_admin_user} ) {
        $ENV{'GK_FEEDER_ADMIN_USER'} = $Models{feeder_admin_user};
    }
    else {
        $ENV{'GK_FEEDER_ADMIN_USER'} = 'valadmin';
    }

    # Determine NBFEEDER_HOST
    # Use feeder_host entry if it exists, default to local host
    $ENV{GK_FEEDER_HOST} = '';
    if ( defined( $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }{ $ENV{GK_STEP} } ) ) {
        if (
            ref $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }{ $ENV{GK_STEP} } eq
            'HASH' )
        {
            if (
                (
                    defined $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }
                    { $ENV{GK_STEP} }{$GkEventType}
                )
              )
            {
                $ENV{GK_FEEDER_HOST} =
                  $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }{ $ENV{GK_STEP} }
                  {$GkEventType};
                $VTMBTool->info(
"Setting FEEDER HOST based on Stepping override $ENV{GK_FEEDER_HOST} for event $GkEventType"
                );
            }
            elsif (
                defined $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }{ $ENV{GK_STEP} }
                {default} )
            {
                $ENV{GK_FEEDER_HOST} =
                  $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }{ $ENV{GK_STEP} }
                  {default};
                $VTMBTool->info(
"Setting FEEDER HOST based on Stepping override $ENV{GK_FEEDER_HOST} for default event"
                );
            }
        }
        else {
            $ENV{GK_FEEDER_HOST} =
              $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }{ $ENV{GK_STEP} };
            $VTMBTool->info(
                "Setting FEEDER HOST based on Stepping override $ENV{GK_FEEDER_HOST}");
        }
    }
    elsif (
        defined( $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }{ $ENV{GK_CLUSTER} } ) )
    {
        if (
            ref $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }{ $ENV{GK_CLUSTER} } eq
            'HASH' )
        {
            if (
                (
                    defined $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }
                    { $ENV{GK_CLUSTER} }{$GkEventType}
                )
              )
            {
                $ENV{GK_FEEDER_HOST} =
                  $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }{ $ENV{GK_CLUSTER} }
                  {$GkEventType};
                $VTMBTool->info(
"Setting FEEDER HOST based on Cluster override $ENV{GK_FEEDER_HOST} for event $GkEventType"
                );
            }
            elsif (
                defined $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }
                { $ENV{GK_CLUSTER} }{default} )
            {
                $ENV{GK_FEEDER_HOST} =
                  $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }{ $ENV{GK_CLUSTER} }
                  {default};
                $VTMBTool->info(
"Setting FEEDER HOST based on Cluster override $ENV{GK_FEEDER_HOST} for default event"
                );
            }
        }
        else {
            $ENV{GK_FEEDER_HOST} =
              $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }{ $ENV{GK_CLUSTER} };
            $VTMBTool->info(
                "Setting FEEDER HOST based on Cluster override $ENV{GK_FEEDER_HOST}");
        }
    }
    elsif ( defined( $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }{default} ) ) {
        if ( ref $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }{default} eq 'HASH' ) {
            if (
                (
                    defined $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }{default}
                    {$GkEventType}
                )
              )
            {
                $ENV{GK_FEEDER_HOST} =
                  $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }{default}{$GkEventType};
                $VTMBTool->info(
"Setting FEEDER HOST based on Host override $ENV{GK_FEEDER_HOST} for event $GkEventType"
                );
            }
            elsif (
                defined $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }{default}
                {default} )
            {
                $ENV{GK_FEEDER_HOST} =
                  $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }{default}{default};
                $VTMBTool->info(
"Setting FEEDER HOST based on Host override $ENV{GK_FEEDER_HOST} for default event"
                );
            }
        }
        else {
            $ENV{GK_FEEDER_HOST} =
              $Models{feeder_host}{ $ENV{USER} }{ $ENV{HOST} }{default};
            $VTMBTool->info(
                "Setting FEEDER HOST based on Host override $ENV{GK_FEEDER_HOST}");
        }
    }
    if ( !$ENV{GK_FEEDER_HOST} ) {
        $ENV{GK_FEEDER_HOST} = $ENV{HOST};
        $VTMBTool->info("Using Default FEEDER HOST $ENV{GK_FEEDER_HOST}");
    }

    # Based on Event Type, set NB variables.
    if ( $ENV{'GK_EVENTTYPE'} eq "mock" ) {
        $task_prefix = "$ENV{'GK_EVENTTYPE'}.$ENV{'MODEL_BASE'}.$ENV{'MY_PID'}";

        # Example of a date format: Wed Jun 24 14:35:14 PDT 2009
        # keep only Jun:24:09:14:35:14
        my $date = `date`;
        chomp $date;
        $date =~ s/\S+\s+(\S+)\s+(\S+)\s+(\S+:\S+:\S+)\s+\S+\s+\S\S(\S+)/$1-$2-$4.$3/;
        $task_tag = "$ENV{'GK_EVENTTYPE'}.$ENV{USER}.$date";

        #$ENV{'NBPOOL'}  = GetNetBactchSettings('NBPOOL');
        #$ENV{'NBCLASS'} = GetNetBactchSettings('NBCLASS');
        #$ENV{'NBQSLOT'} = GetNetBactchSettings('NBQSLOT');
        ( $ENV{'NBPOOL'}, $ENV{'NBCLASS'}, $ENV{'NBQSLOT'} ) = &GetNetBatchSettings();
    }
    else {
        $task_tag = basename( $ENV{'MODEL'} );
        if ( $ENV{'GK_EVENTTYPE'} eq "post-release" ) {
            $task_tag = "post-release.$task_tag";
        }
        $task_prefix = "${task_tag}." . $ENV{'MY_PID'};

        #$ENV{'NBPOOL'}  = GetNetBactchSettings('NBPOOL');
        #$ENV{'NBCLASS'} = GetNetBactchSettings('NBCLASS');
        #$ENV{'NBQSLOT'} = GetNetBactchSettings('NBQSLOT');
        ( $ENV{'NBPOOL'}, $ENV{'NBCLASS'}, $ENV{'NBQSLOT'} ) = &GetNetBatchSettings();

        # Setup Turnin Name and Number or release name
        $dir_name = ${task_tag};
        $dir_num  = $dir_name;
        $dir_num =~ s/turnin//;
        $dir_num =~ s/filter//;
        $dir_num =~ s/\.\d+//;
        $dir_num = $ENV{GK_TURNIN_ID} if (defined $ENV{GK_TURNIN_ID});
    }

    # Set Other variabled that can be used by Configuration File
    $ENV{'GK_WORK_AREA'}   = $ENV{'MODEL'} . "/GATEKEEPER";
    $ENV{'GK_TASK_AREA'}   = $ENV{'GK_WORK_AREA'} . "/NBFeederTaskJobs";
    $ENV{'GK_LOG_AREA'}    = $ENV{'GK_WORK_AREA'} . "/NBFeederLogs";
    $ENV{'GK_TASK_PREFIX'} = $task_prefix;

    #Setup Generatic Object to Hold Information

    $VTMBObj = new VTMBObject(
        GK_STEP      => $ENV{'GK_STEP'},
        GK_CLUSTER   => $ENV{'GK_CLUSTER'},
        GK_EVENTTYPE => $ENV{'GK_EVENTTYPE'},
        TASK_PREFIX  => $task_prefix,
        TASK_TAG     => $task_tag,
        MODEL        => $ENV{'MODEL'},
        TASK_AREA    => $ENV{GK_TASK_AREA},
        LOG_AREA     => $ENV{GK_LOG_AREA},
        WORKAREA     => $ENV{GK_WORK_AREA},
        DIR_NAME     => $dir_name,
        DIR_NUM      => $dir_num,
    ) or die "Error Initializing VTMB Object. Report this bug to Chancellor Archie.\n";

    # We have setup the VTMBObj, lets setup logging.
    &init_log();

    # Determine if Netbatch Overrides exists and use them.
    my $nb_override;
    if ( defined $Models{'netbatch_override'}{'all'}{ $ENV{'SITE'} } ) {
        $nb_override = "$Models{'netbatch_override'}{'all'}{$ENV{'SITE'}}";
        $VTMBTool->info(
            "Global Netbatch Override for Site $ENV{'SITE'} Detected : $nb_override");
        require "$nb_override";
    }
    elsif ( ( defined $Models{'netbatch_override'}{'all'} )
        && -e $Models{'netbatch_override'}{'all'} )
    {
        $nb_override = "$Models{'netbatch_override'}{'all'}";
        $VTMBTool->info("Global Netbatch Override Detected, using file : $nb_override");
        require "$nb_override";
    }
    elsif ( ( defined $Models{'netbatch_override'}{ $ENV{'GK_EVENTTYPE'} } )
        && -e $Models{'netbatch_override'}{ $ENV{'GK_EVENTTYPE'} } )
    {
        $nb_override = "$Models{'netbatch_override'}{$ENV{'GK_EVENTTYPE'}}";
        $VTMBTool->info(
            "$ENV{'GK_EVENTTYPE'} Netbatch Override Detected, using file : $nb_override");
        require "$nb_override";
    }
    elsif (
        ( defined $Models{netbatch_override}{ $ENV{'GK_CLUSTER'} }{ $ENV{'GK_STEP'} } )
        && -e $Models{netbatch_override}{ $ENV{'GK_CLUSTER'} }{ $ENV{'GK_STEP'} } )
    {
        $nb_override =
          "$Models{'netbatch_override'}{$ENV{'GK_CLUSTER'}}{$ENV{'GK_EVENTTYPE'}}";
        $VTMBTool->info(
"$ENV{'GK_CLUSTER'} $ENV{'GK_STEP'} Netbatch Override Detected, using file : $nb_override"
        );
        require "$nb_override";
    }
    else {
        $VTMBTool->info("No Netbatch Override Detected");
    }

    # If there are Global Environment Variable Settings, that need to be applied.
    if ( defined $Models{env} ) {
        foreach my $env_setting ( $Models{env} ) {
            my @env_var_settings = keys(%$env_setting);
            foreach my $env_var (@env_var_settings) {
                if ( ref $env_setting->{$env_var} ne 'HASH' ) {
                    $ENV{$env_var} = $env_setting->{$env_var};
                    $VTMBTool->info(
"  Setting Global Environment Variable from Configuration File: $env_var = $env_setting->{$env_var}"
                    );
                }
                else {
                    my $env_code_something_one_day;
                }
            }
        }
    }

    # If there are GK EventType Specific Environment Settings that need to be applied.
    if ( defined $Models{env}{ $ENV{'GK_EVENTTYPE'} } ) {
        foreach my $env_setting ( $Models{env}{ $ENV{'GK_EVENTTYPE'} } ) {
            my @env_var_settings = keys(%$env_setting);
            foreach my $env_var (@env_var_settings) {
                if ( ref $env_setting->{$env_var} ne 'HASH' ) {
                    $ENV{$env_var} = $env_setting->{$env_var};
                    $VTMBTool->info(
"  Setting $ENV{'GK_EVENTTYPE'} Specific Environment Variable from Configuration File: $env_var = $env_setting->{$env_var}"
                    );
                }
                else {
                    my $env_code_something_one_day;
                }
            }
        }
    }

    # If there are Site Specific Environment Settings that need to be applied.
    if ( defined $Models{env}{ $ENV{'SITE'} } ) {
        foreach my $env_setting ( $Models{env}{ $ENV{'SITE'} } ) {
            my @env_var_settings = keys(%$env_setting);
            foreach my $env_var (@env_var_settings) {
                $ENV{$env_var} = $env_setting->{$env_var};
                $VTMBTool->info(
"  Setting Site Specific Environment Variable from Configuration File: $env_var = $env_setting->{$env_var}"
                );
            }
        }
    }

    # Determine CAMA_MODEL_CACHING_DISK
    if ( defined $Models{cama_model_caching_disk} ) {

        # Look for GkEventType Override for CAMA Disk Settings
        if ( defined $Models{cama_model_caching_disk}{$GkEventType} ) {

            # Determine if Setting is HASH or Value
            # Disk can be setup back on GKEventtype.
            # Within GK Event Type, there is support for Cluster Overrides
            if ( ref $Models{cama_model_caching_disk}{$GkEventType} eq '' ) {
                $ENV{CAMA_MODEL_CACHING_DISK} =
                  $Models{cama_model_caching_disk}{$GkEventType};
                $VTMBTool->info(
                    "CAMA Model Caching Disk based on GK Event = $ENV{'GK_EVENTTYPE'}");
                $VTMBTool->info(
                    " CAMA_MODEL_CACHING_DISK = $ENV{'CAMA_MODEL_CACHING_DISK'} ");
            }
            elsif ( ref $Models{cama_model_caching_disk}{$GkEventType} eq 'HASH' ) {

                # GK EventType Override by Cluster and default
                if (
                    defined $Models{cama_model_caching_disk}{$GkEventType}
                    { $ENV{'GK_CLUSTER'} } )
                {
                    $ENV{CAMA_MODEL_CACHING_DISK} =
                      $Models{cama_model_caching_disk}{$GkEventType}
                      { $ENV{'GK_CLUSTER'} };
                    $VTMBTool->info(
"CAMA Model Caching Disk Cluster Override based on GK Event = $ENV{'GK_EVENTTYPE'}, GK Cluster = $ENV{'GK_CLUSTER'}"
                    );
                    $VTMBTool->info(
                        " CAMA_MODEL_CACHING_DISK = $ENV{'CAMA_MODEL_CACHING_DISK'} ");
                }
                elsif ( defined $Models{cama_model_caching_disk}{$GkEventType}{default} )
                {
                    $ENV{CAMA_MODEL_CACHING_DISK} =
                      $Models{cama_model_caching_disk}{$GkEventType}{default};
                    $VTMBTool->info(
"CAMA Model Caching Disk Cluster Default Override based on GK Event = $ENV{'GK_EVENTTYPE'}'"
                    );
                    $VTMBTool->info(
                        " CAMA_MODEL_CACHING_DISK = $ENV{'CAMA_MODEL_CACHING_DISK'} ");
                }
                else {
                    $VTMBTool->error(
"CAMA Model Caching Disk based on GK Event Override is not correctly specified. At least add a default key"
                    );
                    $VTMBTool->check_errors();
                }
            }
            else {
                $VTMBTool->error(
                    "Default CAMA Model Caching Disk based is not correctly specified.");
                $VTMBTool->check_errors();
            }
        }
        elsif ( defined $Models{cama_model_caching_disk}{ $ENV{'GK_CLUSTER'} } ) {
            $ENV{CAMA_MODEL_CACHING_DISK} =
              $Models{cama_model_caching_disk}{ $ENV{'GK_CLUSTER'} };
            $VTMBTool->info(
                "CAMA Model Caching Disk Override based on Cluster = $ENV{'GK_CLUSTER'}'"
            );
            $VTMBTool->info(
                " CAMA_MODEL_CACHING_DISK = $ENV{'CAMA_MODEL_CACHING_DISK'} ");
        }
        elsif ( defined $Models{cama_model_caching_disk}{default} ) {
            $ENV{CAMA_MODEL_CACHING_DISK} = $Models{cama_model_caching_disk}{default};
            $VTMBTool->info("CAMA Model Caching Disk Cluster Default Override");
            $VTMBTool->info(
                " CAMA_MODEL_CACHING_DISK = $ENV{'CAMA_MODEL_CACHING_DISK'} ");
        }
        elsif (( !defined $Models{cama_model_caching_disk}{ $ENV{'GK_CLUSTER'} } )
            && ( !defined $Models{cama_model_caching_disk}{default} )
            && ( !defined $Models{cama_model_caching_disk}{$GkEventType} ) )
        {
            $VTMBTool->info(
"GK CAMA Model Caching Disk is not setup for Cluster = $ENV{'GK_CLUSTER'}, GK Event Type = $GkEventType "
            );
        }
        else {
            $VTMBTool->error(
"GK CAMA Model Caching Disk is not properly configured in  $ENV{'GK_UTILS_CFG'}"
            );
            $VTMBTool->check_errors();
        }

     # Create CAMA directory if it doesn't exist and only if we are not in print_commands.
        if ( ( defined $ENV{CAMA_MODEL_CACHING_DISK} ) && ( !$print_commands ) ) {

            if ( $GkEventType eq "MOCK" )    # Unregister CAMA Models
            {

                # Unregister the Clone in Clone ModelRoot
                if ( defined $Models{clone_in_clone} ) {
                    $VTMBTool->info(
" Unregistering CAMA Model located at $ENV{'CAMA_MODEL_CACHING_DISK'}/$Models{clone_in_clone} "
                    );
                    $cama_unreg = $Models{unregisterCaMa};
                    $cama_unreg =~ s/RTL_PROJ_BIN/$ENV{'RTL_PROJ_BIN'}/;
                    $cama_unreg =~ s/MODEL/$ENV{'MODEL'}\/$Models{clone_in_clone}/;
                    if ( $VTMBTool->run( $cama_unreg, \@cama_unreg_output ) == 0 ) {
                        $VTMBTool->info(" Clone in Clone CAMA Model Unregistered.");
                    }
                    else {
                        $VTMBTool->info(
" Clone in Clone CAMA Model was not successfully Unregistered."
                        );
                    }
                }

                # Unregister the ModelROOT
                $VTMBTool->info(
" Unregistering CAMA Model located at $ENV{'CAMA_MODEL_CACHING_DISK'} "
                );
                $cama_unreg = $Models{unregisterCaMa};
                $cama_unreg =~ s/RTL_PROJ_BIN/$ENV{'RTL_PROJ_BIN'}/g;
                $cama_unreg =~ s/RTL_PROJ_TOOLS/$ENV{'RTL_PROJ_TOOLS'}/g;
                $cama_unreg =~ s/MODEL/$ENV{'MODEL'}/g;
                $cama_unreg =~ s/GK_WORK_AREA/$ENV{'GK_WORK_AREA'}/g;
                $cama_unreg =~ s/GK_TASK_PREFIX/$ENV{'GK_TASK_PREFIX'}/g;
                if ( $VTMBTool->run( $cama_unreg, \@cama_unreg_output ) == 0 ) {
                    $VTMBTool->info(" CAMA Model Unregistered.");
                }
                else {
                    $VTMBTool->info(" CAMA Model was not successfully Unregistered.");
                }
            }
            if ( $ENV{CAMA_MODEL_CACHING_DISK}
                && !-d $ENV{CAMA_MODEL_CACHING_DISK} )
            {
                $VTMBTool->info(
" CAMA Model Caching area does not exists at $ENV{'CAMA_MODEL_CACHING_DISK'} "
                );
                $VTMBTool->info("  Creating Disk $ENV{'CAMA_MODEL_CACHING_DISK'} ");
                if ( !$print_commands ) {
                    $VTMBTool->create_directories("$ENV{'CAMA_MODEL_CACHING_DISK'}");

                    # Change Permissions on disk to allow group access.
                    # This area will be used by everyone, chmod group permissions.
                    chmod 0770, $ENV{'CAMA_MODEL_CACHING_DISK'};
                }
            }

        }
    }

    # Set Permissions & Groups during GK Process if specified in CFG file.
    if (   ( defined $Models{model_root_chmod}{ $ENV{'GK_EVENTTYPE'} } )
        && ( !$print_commands ) )
    {
        my ( $chmod_cmd, @chmod_results );
        $chmod_cmd =
          "chmod $Models{model_root_chmod}{$ENV{'GK_EVENTTYPE'}} $ENV{'MODEL'}";
        if ( $VTMBTool->run( $chmod_cmd, @chmod_results ) == 0 ) {
            $VTMBTool->info(
" Permission on MODEL changed to chmod $Models{model_root_chmod}{$ENV{'GK_EVENTTYPE'}}"
            );
        }
        else {
            $VTMBTool->error(
" Permission on MODEL could not be changed to chmod $Models{model_root_chmod}{$ENV{'GK_EVENTTYPE'}}"
            );
        }
    }
    if (   ( defined $Models{model_root_group}{ $ENV{'GK_EVENTTYPE'} } )
        && ( !$print_commands ) )
    {
        my ( $chgrp_cmd, @chgrp_results );
        $chgrp_cmd =
          "chgrp $Models{model_root_group}{$ENV{'GK_EVENTTYPE'}} $ENV{'MODEL'}";
        if ( $VTMBTool->run( $chgrp_cmd, @chgrp_results ) == 0 ) {
            $VTMBTool->info(
" Group on MODEL changed to chgrp $Models{model_root_chgrp}{$ENV{'GK_EVENTTYPE'}}"
            );
        }
        else {
            $VTMBTool->error(
" Group on MODEL could not be changed to chgrp $Models{model_root_chgrp}{$ENV{'GK_EVENTTYPE'}}"
            );
        }
    }

    if ( defined $Models{nbflow_resource_xml}{ $ENV{GK_CLUSTER} } ) {
        my $resource_xml = $Models{nbflow_resource_xml}{ $ENV{GK_CLUSTER} };
        $resource_xml =~ s/RTL_PROJ_BIN/$ENV{RTL_PROJ_BIN}/g;
        $resource_xml =~ s/RTL_PROJ_TOOLS/$ENV{RTL_PROJ_TOOLS}/g;
        $resource_xml =~ s/MODEL/$ENV{MODEL}/g;
        $resource_xml =~ s/GK_WORK_AREA/$ENV{GK_WORK_AREA}/g;
        $resource_xml =~ s/PROGRAM_DIR/${ProgramDir}/g;
        $ENV{GK_NBFLOW_RESOURCE_XML} = $resource_xml;
    }
    if ( defined $ENV{GK_NBFLOW_RESOURCE_XML} && !$print_commands ) {
        if ( -f $ENV{GK_NBFLOW_RESOURCE_XML} ) {
            $VTMBTool->info(
                " Will use simbuild nbflow resource xml file $ENV{GK_NBFLOW_RESOURCE_XML}"
            );
        }
        else {
            $VTMBTool->error(
" Could not find simbuild nbflow resource xml file $ENV{GK_NBFLOW_RESOURCE_XML}"
            );
        }
    }

    # Terminate on errors
    $VTMBTool->check_errors();
}

#-------------------------------------------------------------------------------
# GetNetBatchSetting()
#   Return the netbatch setting.
#-------------------------------------------------------------------------------
sub GetNetBatchSettings {

    # Display status and set up indentation
    $VTMBTool->indent_msg(0);
    $VTMBTool->info("Determining Netbatch Settings based on Configuration File");
    $VTMBTool->indent_msg(2);
    my ( $pool, $class, $qslot );

    # Determine Netbatch Settings
    if ( ( $ENV{'GK_EVENTTYPE'} eq "mock" ) && $ENV{'GK_MOCK_PRIORITY_QSLOT'} ) {
        if ( defined $Models{netbatch}{ $ENV{'GK_CLUSTER'} }{mockpriority} ) {
            $pool  = $Models{netbatch}{ $ENV{'GK_CLUSTER'} }{mockpriority}[0];
            $class = $Models{netbatch}{ $ENV{'GK_CLUSTER'} }{mockpriority}[1];
            $qslot = $Models{netbatch}{ $ENV{'GK_CLUSTER'} }{mockpriority}[2];
        }
        elsif ( defined $Models{netbatch}{'all'}{mockpriority} ) {
            $pool  = $Models{netbatch}{'all'}{mockpriority}[0];
            $class = $Models{netbatch}{'all'}{mockpriority}[1];
            $qslot = $Models{netbatch}{'all'}{mockpriority}[2];
        }
        else {
            $VTMBTool->error(
"Priority Mock Turnin Netbatch Configuration is not defined. Contact GK Owner."
            );
        }
    }
    elsif (( $ENV{'GK_EVENTTYPE'} eq "mock" )
        && ( defined $Models{netbatch}{ $ENV{SITE} }{mock} ) )
    {
        $pool  = $Models{netbatch}{ $ENV{SITE} }{mock}[0];
        $class = $Models{netbatch}{ $ENV{SITE} }{mock}[1];
        $qslot = $Models{netbatch}{ $ENV{SITE} }{mock}[2];
    }
    else {
        if ( defined $Models{netbatch}{ $ENV{'GK_CLUSTER'} }{ $ENV{'GK_EVENTTYPE'} } ) {
            $pool  = $Models{netbatch}{ $ENV{'GK_CLUSTER'} }{ $ENV{'GK_EVENTTYPE'} }[0];
            $class = $Models{netbatch}{ $ENV{'GK_CLUSTER'} }{ $ENV{'GK_EVENTTYPE'} }[1];
            $qslot = $Models{netbatch}{ $ENV{'GK_CLUSTER'} }{ $ENV{'GK_EVENTTYPE'} }[2];
        }
        elsif ( defined $Models{netbatch}{'all'}{ $ENV{'GK_EVENTTYPE'} } ) {
            $pool  = $Models{netbatch}{'all'}{ $ENV{'GK_EVENTTYPE'} }[0];
            $class = $Models{netbatch}{'all'}{ $ENV{'GK_EVENTTYPE'} }[1];
            $qslot = $Models{netbatch}{'all'}{ $ENV{'GK_EVENTTYPE'} }[2];
        }
        else {
            $VTMBTool->error("Netbatch Configuration is not defined. Contact GK Owner.");
        }
    }

    # Confirm NB variables are always set.
    if ( !defined $pool ) {
        $VTMBTool->error(
            "Netbatch Variable NBPOOL is not defined thru Configuration setting");
    }
    if ( !defined $class ) {
        $VTMBTool->error(
            "Netbatch Variable NBCLASS is not defined thru Configuration setting");
    }
    if ( !defined $qslot ) {
        $VTMBTool->error(
            "Netbatch Variable NBQSLOT is not defined thru Configuration setting");
    }

    # Terminate on errors
    $VTMBTool->check_errors();

    # If no errors are found, return NB Settings.

    return ( $pool, $class, $qslot );
}

#-------------------------------------------------------------------------------
# GetNetBactchSetting()
#   Return the netbatch setting.
#-------------------------------------------------------------------------------
################### REMOVE this Code after 11/30/2010
#sub GetNetBactchSettings
#{
#   my $type = shift;
#   my $ind = ($type eq 'NBPOOL') ? 0 :  ($type eq 'NBCLASS') ? 1 : 2;
#
#   if(($ENV{'GK_EVENTTYPE'} eq "mock") && $ENV{'GK_MOCK_PRIORITY_QSLOT'})
#    {
#      return exists $Models{netbatch}{$ENV{SITE}}{mockpriority} ?
#                        $Models{netbatch}{$ENV{SITE}}{mockpriority}[$ind] :
#                        $Models{netbatch}{'all'}{mockpriority}[$ind];
#    }
#   else
#    {
#      return exists $Models{netbatch}{$ENV{SITE}}{$ENV{'GK_EVENTTYPE'}} ?
#                        $Models{netbatch}{$ENV{SITE}}{$ENV{'GK_EVENTTYPE'}}[$ind] :
#                        $Models{netbatch}{'all'}{$ENV{'GK_EVENTTYPE'}}[$ind];
#    }
#}
#
#-------------------------------------------------------------------------------
# BuildModels()
#   Build All Models at the FC,Super Cluster, or Cluster level
#-------------------------------------------------------------------------------

sub gk_smart_build {

    $VTMBTool->set( 'QUIET', 1 ) if !$ENV{'DISABLE_QUIET_MODE'};

    # Get list of BuildStages (Applicable for BuildModels sub-routine)
    # Enable all by default
    foreach my $build_cmd ( @{ $Models{simbuild_cmds} } ) {
        my $stage   = $build_cmd->{NAME};
        my $context = $build_cmd->{CMDS};
        chomp $context;

        if ( $context =~ /--context\s+(\S+)\s*/ ) {
            $context = $1;
        }
        elsif ( $context =~ /-c\s+(\S+)\s*/ ) {
            $context = $1;
        }
        else {
            $context = "NONE";
        }

        my @duts = ();
        if ( !defined $build_cmd->{DUTS} ) {
            undef @duts;
            push @duts, $build_cmd->{CLUSTER};
        }
        else {
            @duts = split( / /, $build_cmd->{DUTS} );
        }

        foreach my $dut (@duts) {
            $RunStages{$dut}{$context} = 0;
        }
    }

##Smart GK Build logic here

    $VTMBTool->log("SmartGK: Enabling GK Smart build");
    $VTMBTool->log("SmartGK: Contents of unmodified RunStages");
    &hashRead(%RunStages);
    $VTMBTool->log("SmartGK: Build_all value: $build_all");
    if ( $ENV{GK_SMART2_MODE} ) {
        $VTMBTool->log("SmartGK: Running SmartBuild2.0");
        &smart_logic( \%RunStages );
        $VTMBTool->log("SmartGK: Build_all value after SmartBuild2.0: $build_all");
    }
    &hashRead(%RunStages);

    my ( $git_cmd, $git_HEAD );
    $git_cmd  = "git rev-parse HEAD";
    $git_HEAD = `$git_cmd`;
    chomp $git_HEAD;
    my $show_intersect_op = "$ENV{GK_MODELROOT}/log/show_intersect_$git_HEAD";
    if ( -e $show_intersect_op && -s $show_intersect_op ) {
        $VTMBTool->log("show_intersect output file: $show_intersect_op");

        #Setting environtment variable to be used by other flows
        $ENV{'SHOW_INTERSECT_OUTPUT'} = $show_intersect_op;
        open( SHOWINTERSECT_OPFILE, "$show_intersect_op" )
          || warn "Cannot open file $show_intersect_op\n";
        my @dut_context = <SHOWINTERSECT_OPFILE>;
        $VTMBTool->log("Skipping show-intersect since it is already run");
        for my $item (@dut_context) {
            my ( $dut, $context ) = split( /\s+/, $item );
            %{ $dut_contexts{$dut} } = () if ( !exists $dut_contexts{$dut} );

            $context = "NONE" if ( !$context );
            $dut_contexts{$dut}{$context} = 1;

            ## FIXME: Hardcode the gt_sd dut. This should be done via a key
            ## in the build recipe, e.g.:
            ## ALWAYS_RUN => 1,
            if ( $dut eq "gt" ) {
                $dut_contexts{'gt_sd'}{'GT_CFG_GT2'} = 1;
            }
            if ( $dut eq "cnlh" ) {
                $dut_contexts{'cnlh_sd'}{$context} = 1;
            }
            if ( $dut eq "cnl" ) {
                $dut_contexts{'cnl_sd'}{$context} = 1;
            }

            if ( $dut eq "icl" ) {
                $dut_contexts{'icl_sd'}{$context} = 1;
            }
            if ( $dut eq "icl_uum" ) {
                $dut_contexts{'icl_uum_sd'}{$context} = 1;
            }
            if ( $dut eq "icl_11p5" ) {
                $dut_contexts{'icl_11p5_sd'}{$context} = 1;
            }
            if ( $dut eq "tgl" ) {
                $dut_contexts{'tgl_sd'}{$context} = 1;
            }
            if ( $dut eq "lkf" ) {
                $dut_contexts{'lkf_sd'}{$context} = 1;
            }
            $dut_contexts{'mipiclt'}{$context} = 1;

        }
    }
    else {

        $VTMBTool->log("show_intersect log file is either empty or does not exist");
        $VTMBTool->log("SmartGK: About to run show_intersect");
        &showIntersect();
    }

    $VTMBTool->log("SmartGK: Contents of RunStages after showIntersect is");
    &hashRead(%RunStages);
    $VTMBTool->log("SmartGK: Build_all value after showIntersect is: $build_all");
    &updateRunStages();

    $VTMBTool->log("SmartGK: Contents of RunStages after updateRunStages is");
    &hashRead(%RunStages);

    #FIXME: If no targets are found then force GT target.
    if ( !scalar( @{ $Models{simbuild_cmds} } ) ) {
        $VTMBTool->log("SmartGK: No smartbuild targets found; forcing gt target.");
        %dut_contexts = ();

        $dut_contexts{'gt'} = { 'NONE' => 1, };
    }

    if ( $build_all == 1 ) {
        &hashUpdate( \%RunStages, 1 );

        $VTMBTool->log("SmartGK: Contents of RunStages after build_all override is");
        &hashRead(%RunStages);
    }

## Skip filter if no job to run found #FIXME
    my $build_something = 0;
    foreach my $dut1 ( keys %RunStages ) {
        foreach my $context1 ( keys %{ $RunStages{$dut1} } ) {
            if ( $RunStages{$dut1}{$context1} == 1 ) {
                $build_something = 1;
            }
        }
    }

    if ( $build_something == 0 and !scalar(@smart_waivers)) {
        $VTMBTool->log("SmartGK: No job to run.Skipping filter build and regress jobs");
        if ( defined $Models{enable_fev_check} ) {
            if ( !$Models{enable_fev_check} ) {
                exit(0);
            }
        }
        if ( not defined $Models{enable_fev_check} ) {
            exit(0);
        }

    }
    &get_smart_waiver_jobs if (defined @smart_waivers);

}

sub hashRead {
    my %hash = @_;
    my ( $key, $contexts, $context, $value );

    foreach my $keys ( keys %hash ) {
        foreach my $keys1 ( keys %{ $hash{$keys} } ) {
            $VTMBTool->log(
                "SmartGK: DUT:$keys CONTEXT:$keys1 VALUE:$hash{$keys}{$keys1}");
        }
    }
}

sub hashUpdate {

    my ( $hash, $updatevalue ) = @_;
    my ( $key, $contexts, $context, $value );

    my %hash1 = %$hash;

    foreach my $keys ( keys %hash1 ) {
        foreach my $keys1 ( keys %{ $hash1{$keys} } ) {
            $hash1{$keys}{$keys1} = $updatevalue;
        }
    }

}

sub smart_logic {
    my $RunStages = shift;         # keys of %$duts are the DUTs which are being build
    my $model     = $ENV{MODEL};
    $build_all = 0;
    my @smart_buildable_abs_paths =
      map { File::Spec->join( $model, $_ ) } @smart_buildable_paths;
    my $smart_buildable_paths_re = '(?:' . join( "|", @smart_buildable_abs_paths ) . ')';

    if ( !exists $ENV{'GK_FILES_CHANGED'} ) {
        $VTMBTool->log("SmartGK: \$GK_FILES_CHANGED was not set. Disabling smartbuild");
        $build_all = 1;            #FIX ME

    }
    else {
        my $files_changed_cmd = "cat $ENV{'GK_FILES_CHANGED'}";
        my @files_changed     = qw();
        $VTMBTool->run( $files_changed_cmd, \@files_changed );
        $VTMBTool->log(
            "\n\nSmart GK: Files Changed for this turnin. Inside Smart build logic\n");
        @fileschanged = @files_changed; # Added for conditional content feature
        foreach (@files_changed) {
            $VTMBTool->log("$_");
        }

        if ($?) {
            $VTMBTool->log("SmartGK: Unable to cat [$ENV{'GK_FILES_CHANGED'}]: $!");
            $build_all = 1;
        }
        my $num_of_files = scalar(@files_changed);
        my $num_of_swaiver_files = 0;

        if ( ! $num_of_files ) {
            $VTMBTool->log("Smart GK: Zero ($num_of_files) files changed.");
            $VTMBTool->log("Smart GK: Disabling Smart Build. Building all");
            $build_all = 1;
            return;
        }

        ## Check to ensure that every changed file is in one of the allowed
        ## smart-build paths. If any are not, then disqualify smart-build
        foreach my $fname (@files_changed) {
            &trim($fname);
            my $fpath = File::Spec->join( $model, $fname );

            if ( $fpath !~ m/^$smart_buildable_paths_re/ and not defined
                $Models{smart_waiver_mapping}{$fname} ) {
                $VTMBTool->log("SmartGK: *** Disabling smartbuild due to file [$fpath].");

                #FIX ME HANDLE SMART REGEX
                #$build_all = 1;
                last;
            }
        }

        # everything seems to be fine. Start actual logic here
        my $config_file = $Models{smart_build2_config_file};
        if ( !( -e $config_file ) ) {
            $VTMBTool->log(
                "\n\nSmart GK: Config file $config_file not present/readable\n");
            $build_all = 1;
            $ENV{'GK_SMART2_MODE'} = 0;
            return;
        }
        my $smart_config_cmd = "cat $config_file";
        my @smart_configs    = qw();
        $VTMBTool->run( $smart_config_cmd, \@smart_configs );
        $VTMBTool->log("\n\nSmart GK: Reading smart configs\n");

        if ( ! scalar(@smart_configs) ) {
            $VTMBTool->log("Smart GK: Zero config lines in SmartBuild Config "
                          ."file: $config_file.");
            $VTMBTool->log("Smart GK: Disabling Smart Build. Building all");
            $build_all = 1;
            return;
        }

        my %smart_config_hash;
        my %file_regex_hash;    #mapping of what regex matches a filepath
        foreach my $line (@smart_configs) {
            chomp $line;
            $line =~ s/^\s+//g;    # Remove leading spaces
            $line =~ s/\s+$//g;    # Remove trailing spaces
            if ( $line =~ /^#/ ) {
                $VTMBTool->log("\n\nSmart GK: Comment found in config file - $line \n");
                next;
            }
            my ( $path, $action ) = split /:/, $line, 2;    #REGEX:WHAT TO REGRESS
                    # Remove leading and trailing spaces from patterns
            $path   =~ s/^\s+//g;
            $path   =~ s/\s+$//g;
            $action =~ s/^\s+//g;
            $action =~ s/\s+$//g;
            $smart_config_hash{$path} = $action;
        }
        foreach my $filepath (@files_changed) {
            &trim($filepath);
            if ( $filepath =~ /^src/ ) {
                $VTMBTool->log("\nSmart GK: Skipping file $filepath as it "
                              ."will be processed in intersect command\n");
                next;
            }
            $file_regex_hash{$filepath} = "";
            foreach my $reg ( sort keys %smart_config_hash ) {

                #reg value will be in alphabetic ordering
                if ( defined $Models{smart_waiver_mapping}{$filepath}){
                    $file_regex_hash{$filepath} = 'sWaiver';
                }
                elsif ( $filepath =~ /^$reg/ ) {
                    $VTMBTool->log("Smart GK: $reg matches $filepath");
                    $file_regex_hash{$filepath} = $reg;
                }
            }
        }
        foreach my $filepath ( sort keys %file_regex_hash ) {
            my $recommend;
            my $dut;
            my $contextcfg;
            if ( $file_regex_hash{$filepath} =~ /\\w/ ) {
                $dut = $1 if ( $filepath =~ /$file_regex_hash{$filepath}/ );
                 $contextcfg = $2 if ( $filepath =~ /$file_regex_hash{$filepath}/ );
                $recommend = $smart_config_hash{ $file_regex_hash{$filepath} };

#   print "SmartGK - Build $dut for $filepath. Config value is $smart_config_hash{$file_regex_hash{$filepath}}\n";
                $VTMBTool->log("Smart GK2.0: SmartGK - "
                              ."Build $dut for $filepath. Config value is "
                              ."$smart_config_hash{$file_regex_hash{$filepath}}");
            }
            elsif ( $file_regex_hash{$filepath} eq "sWaiver" ) {
                $recommend = 'smartWaiver';
                $VTMBTool->log("SmartWaiver - For waiver file: $filepath. Build"
                              ." check $Models{smart_waiver_mapping}{$filepath}[0]");
            }
            else {
                $recommend = $smart_config_hash{ $file_regex_hash{$filepath} };
                $VTMBTool->log("SmartGK - For $filepath, Config value is "
                              ."$smart_config_hash{$file_regex_hash{$filepath}}");
            }

            #Now based on value decide what to run
            if ( $recommend eq "smartWaiver" ) {
                # Smart Waiver: If a check's waiver file is changed, run only that check
                # plus dependencies and/or any other check(s) specified
                # Format for Smart Waiver Config ==>
                #     <waiver_file> => [<check>,<string of comma-separated-checks>]
                # Optionally, after the check, you can mention
                #     specific comma separated checks -> ...'spyglass','FACT,export_to_sd'
                #     and space separated duts -> ...'spyglass','FACT,export_to_sd(gt ga_clt)'
                # Example:
                # $Models{smart_waiver_mapping} = {
                #     cfg/spyglass/waiver_file => ['spyglass','FACT,export_to_sd(gt ga_clt)'],
                # };

                my $check_name = $Models{smart_waiver_mapping}{$filepath}[0];
                push @smart_waivers, $check_name;
                $VTMBTool->log("SmartWaiver: Waiver file $filepath changed. "
                               ."Will build check: $check_name");
                my $checks_list = $Models{smart_waiver_mapping}{$filepath}[1];
                if ($checks_list){
                    foreach my $tmp_check (split /,/, $checks_list){
                        push @smart_waivers, $tmp_check;
                        $VTMBTool->log("SmartWaiver: Waiver file $filepath changed. "
                                       ."Build additional check: $tmp_check");
                    }
                }
                $num_of_swaiver_files++;
            }
            elsif ( $recommend eq "none" ) {
                $VTMBTool->log(
                    "SmartGK - Skipping file $filepath as Recoomendation is $recommend");
                next;
            }
            elsif ( $recommend eq "all" ) {
                $build_all = 1;
                foreach my $dut (%RunStages) {
                    foreach my $context ( %{ $RunStages{$dut} } ) {
                        $dut_contexts{$dut}{$context} = 1;
                    }
                }
                $VTMBTool->log(
                    "SmartGK - Recom is to build all - $recommend for file $filepath");
            }
             elsif ( $recommend eq "dut" ) {
                    if ( exists $RunStages->{$dut} ) {
                    $VTMBTool->log("SmartGK - Building $dut for $filepath");
                    foreach my $context ( %{ $RunStages{$dut} } ) {

                        #$RunStages{$dut}{$context} = 1;
                        $dut_contexts{$dut}{$context} = 1;
                    }
                }
                else {
                    $VTMBTool->log("SmartGK -  Skipping $dut");
                }
            }
            elsif ( $recommend eq "context" ) {

            #print "SmartGK - Build context for all DUTs - Recommendation - $recommend\n";
                $recommend = $dut;
                $VTMBTool->log("SmartGK: Building $recommend context for all DUTs\n");

                # TODO add a forloop to enable context for all DUTs.
                foreach my $duts (%RunStages) {

                    #$RunStages{$duts}{$recommend} = 1;
                    $dut_contexts{$duts}{$recommend} = 1;
                }
            }
            elsif ( $recommend =~ /^dutlist/ ) {

                # Format: dutlist:gt,pipeve
                my $list = $recommend;
                $list =~ s/dutlist\://;
                my @duts = split /,/, $list;
                foreach my $d (@duts) {
                    if ( !exists $RunStages->{$d} ) {
                        $VTMBTool->log(
"SmartGK - Skipping $d for $filepath as it in not part of recipe"
                        );
                    }
                    else {
                        $VTMBTool->log("SmartGK - Building $d for $filepath");
                        foreach my $context ( %{ $RunStages{$d} } ) {
                            $dut_contexts{$d}{$context} = 1;
                        }
                    }
                }
            }
#Sandeep
            elsif ( $recommend =~ /^dutctxt/ ) {
               #Format: dutctxt:gt if gt isn't in the name of the directory, else, it would just be dutctxt;
               if($contextcfg eq "" ){
                  $contextcfg = $dut;
                  my $list = $recommend;
                  $list =~ s/dutctxt\://;
                  $dut = $list;
               }

               if ( !exists $RunStages->{$dut} ) {
                   $VTMBTool->log(
"SmartGK - Skip $dut for $filepath as it in not part of recipe"
                   );
               }
               else {
                   $VTMBTool->log("SmartGK - Building $dut for $filepath");
                   $dut_contexts{$dut}{$contextcfg} = 1;

               }

            }

            else {
                $build_all = 1;
                foreach my $dut (%RunStages) {
                    foreach my $context ( %{ $RunStages{$dut} } ) {
                        $dut_contexts{$dut}{$context} = 1;
                    }
                }
                $VTMBTool->log("SmartGK: Building everything. No recommendation found\n");
            }
        }
        $VTMBTool->log("SmartGK: Checking for always run in smart config file\n");
        if ( exists $smart_config_hash{'ALWAYS_RUN'} ) {
            my @duts = split /,/, $smart_config_hash{'ALWAYS_RUN'};
            $VTMBTool->log("SmartGK: ALWAYS_RUN block value in $config_file: @duts\n");
            foreach my $d (@duts) {
                if ( !exists $RunStages->{$d} ) {
                    $VTMBTool->log(
                        "SmartGK - Skipping $d for ALWAYS_RUN as it in not part of recipe"
                    );
                }
                else {
                    $VTMBTool->log("SmartGK - Building $d as part of ALWAYS_RUN");
                    foreach my $context ( %{ $RunStages{$d} } ) {
                        $dut_contexts{$d}{$context} = 1;
                    }
                }
            }
        }
        else {
            $VTMBTool->log("SmartGK: Always run block not found in $config_file\n");
        }

        # Skip regressions if only waiver files are changed.
        if ($num_of_files and $num_of_swaiver_files and
            @smart_waivers and $num_of_files == $num_of_swaiver_files){
            $VTMBTool->log("SmartWaiver - Number of changed files ($num_of_files) "
                          ."and waiver files ($num_of_swaiver_files) are equal.");
            $VTMBTool->log("              Disabling regressions for this run");
            $VTMBCmdline->{'ARGUMENTS'}->{'-build_only'}->{'VALUE'} = 1;
        }
    }
}

sub check_run_fact()
{
    my $run_fact = 1;

    if ( !exists $ENV{'GK_BUNDLE_FILES_CHANGED'} ) {
    #if ( !exists $ENV{'GK_FILES_CHANGED'} ) {
        $VTMBTool->log("Check Fact to be run: \$GK_BUNDLE_FILES_CHANGED was not set. Fact will run\n");
         return $run_fact;            #FIX ME

    }
    else {
        my $files_changed_cmd = "cat $ENV{'GK_BUNDLE_FILES_CHANGED'}";
        my @files_changed     = qw();
        $VTMBTool->run( $files_changed_cmd, \@files_changed );
        if ($?) {
            $VTMBTool->log("Check Fact to be run: Unable to cat [$ENV{'GK_BUNDLE_FILES_CHANGED'}]: $!");
            return $run_fact;
        }
        # Process for pruning FACT
        # Sample input
        #my @fact_regex = (
        #             "src/units/*tb*",
        #             "src/units/*trk*",
        #             "src/units/*cov*",
        #             "src/units/*uvm*",
        #             "src/units/gt_*",
        #             "src/units/*check*",
        #             "cfg_env/*",
        #             "cfg/*",
        #             );

        return $run_fact if (! defined $Models{$ENV{'GK_CLUSTER'}}{fact_regex});

        my @fact_regex = @{$Models{$ENV{'GK_CLUSTER'}}{fact_regex}};
        my %hash_f; # Contains list of paths which should not run FACT
        foreach (@fact_regex)
        {
            my @allf = glob($_[0]);
            foreach my $f (@allf)
            {
               $hash_f{$f} = 1;
            }
        }
        my %files_hash;
        foreach ( @files_changed)
        {
            chomp $_;
            $files_hash{$_} = 0;
        }
        foreach my $f (sort keys %files_hash)
        {
             chomp $f;
             foreach my $reg (sort keys %hash_f)
             {
                 next if ($files_hash{$f} == 1);  # already processed
                 if ($f =~ /^$reg/)
                 {
                       $files_hash{$f} = 1;
                       $VTMBTool->info("File Hash $f: $files_hash{$f} matches $reg\n");
                       $VTMBTool->log("File Hash $f: $files_hash{$f} matches $reg\n");
                       $run_fact = 0;
                       last;
                 }  else {
                       $VTMBTool->debug("File Hash $f: $files_hash{$f} not matches $reg \n");
                 }
             }
        }
        foreach (sort keys %files_hash)
        {
           if ($files_hash{$_} == 0)
           {
                $run_fact = 1;
                $VTMBTool->debug("Enabling FACT due to $_ \n");
                last;
           }
        }

        $VTMBTool->debug("Disable FACT status = $run_fact \n");

     }
     return $run_fact;
}

sub showIntersect {
    my $model   = $ENV{MODEL};
    my $dot_git = File::Spec->join( $model, '.git' );
    my @stdout  = ();

    if ( ( $build_all == 1 ) && ( !$ENV{GK_SMART2_MODE} ) ) {
        $build_all = 0;
    }
    ## These are the paths that contain collateral allowed for smartbuild. Any
    ## changed files /not/ in these paths will disqualify us from using smart-
    ## build.
    my @smart_buildable_abs_paths =
      map { File::Spec->join( $model, $_ ) } @smart_buildable_paths;
    my $smart_buildable_paths_re = '(?:' . join( "|", @smart_buildable_abs_paths ) . ')';

    if ( !exists $ENV{'GK_FILES_CHANGED'} ) {
        $VTMBTool->log("SmartGK: \$GK_FILES_CHANGED was not set. Disabling smartbuild");
        $build_all = 1;

    }
    else {

        my $files_changed_cmd = "cat $ENV{'GK_FILES_CHANGED'}";
        my @files_changed     = qw();
        $VTMBTool->run( $files_changed_cmd, \@files_changed );
        $VTMBTool->log("\n\nSmart GK: Files Changed for this turnin");
        @fileschanged = @files_changed; # Added for conditional content feature
        foreach (@files_changed) {
            $VTMBTool->log("$_");
        }

        if ($?) {
            $VTMBTool->log("SmartGK: Unable to cat [$ENV{'GK_FILES_CHANGED'}]: $!");
            $build_all = 1;
        }

        ## Check to ensure that every changed file is in one of the allowed
        ## smart-build paths. If any are not, then disqualify smart-build
        foreach my $fname (@files_changed) {
            &trim($fname);
            my $fpath = File::Spec->join( $model, $fname );

            if ( $fpath =~ m/^$smart_buildable_paths_re/ and not defined  # Logic reverted by Akshat
                $Models{smart_waiver_mapping}{$fname} ) {
                $VTMBTool->log(
"SmartGK: Enabling show_intersect() in smartbuild due to file [$fpath]."
                );
                $build_all = 0;                                 # FIX ME
                last;
            }
            else {
                if ( !$ENV{GK_SMART2_MODE} ) {
                    $build_all = 1;
                    last;
                }
            }
        }
    }

    if ( !$build_all ) {
        my $gnr_show_intersect_cmd = "dawrap gnr show_intersect -m $model --meta";
        my ( $commit_id_one, $commit_id_two ) = &getCommitIDs($dot_git);
        if ( $commit_id_one && $commit_id_two ) {
            $gnr_show_intersect_cmd .= " $commit_id_one $commit_id_two";
        }

        $VTMBTool->log("About to run command");
        $VTMBTool->log("$gnr_show_intersect_cmd");
        if ( $VTMBTool->run( $gnr_show_intersect_cmd, \@stdout ) != 0 ) {
            $VTMBTool->log("SmartGK: Error during 'GNR show_intersect' [$?]");
            $build_all = 1;
        }

        $VTMBTool->log("gnr show_intersect output:");
        if (@stdout) {
            foreach (@stdout) {
                chomp;
                $VTMBTool->log($_);
            }
        }
        else {
            $VTMBTool->log("<none>");
        }

        # DUT+context hash pairings
        for my $item (@stdout) {
            my ( $dut, $context ) = split( /\s+/, $item );
            %{ $dut_contexts{$dut} } = () if ( !exists $dut_contexts{$dut} );

            $context = "NONE" if ( !$context );
            $dut_contexts{$dut}{$context} = 1;

            ## FIXME: Hardcode the gt_sd dut. This should be done via a key
            ## in the build recipe, e.g.:
            ## ALWAYS_RUN => 1,
            if ( $dut eq "gt" ) {
                $dut_contexts{'gt_sd'}{'GT_CFG_GT2'} = 1;
            }
            if ( $dut eq "cnlh" ) {
                $dut_contexts{'cnlh_sd'}{$context} = 1;
            }
            if ( $dut eq "cnl" ) {
                $dut_contexts{'cnl_sd'}{$context} = 1;
            }

            if ( $dut eq "icl" ) {
                $dut_contexts{'icl_sd'}{$context} = 1;
            }
            if ( $dut eq "icl_uum" ) {
                $dut_contexts{'icl_uum_sd'}{$context} = 1;
            }
            if ( $dut eq "icl_11p5" ) {
                $dut_contexts{'icl_11p5_sd'}{$context} = 1;
            }
            if ( $dut eq "tgl" ) {
                $dut_contexts{'tgl_sd'}{$context} = 1;
            }
            if ( $dut eq "lkf" ) {
                $dut_contexts{'lkf_sd'}{$context} = 1;
            }

            $dut_contexts{'mipiclt'}{$context} = 1;

        }
    }
}

sub getCommitIDs {
    my $model   = $ENV{MODEL};
    my $dot_git = shift;

    # Find LCA and user commit
    my $command = "git --git-dir $dot_git --work-tree $model rev-parse ORIG_HEAD";
    $VTMBTool->log("Invoking [$command].");
    my $user_commit_id = `$command`;
    &trim($user_commit_id);
    $VTMBTool->log("User Commit ID is $user_commit_id");

    $command =
"git --git-dir $dot_git --work-tree $model rev-parse --default HEAD^2 --verify FETCH_HEAD";
    $VTMBTool->log("Invoking [$command].");
    my $gk_commit_id = `$command`;
    &trim($gk_commit_id);
    $VTMBTool->log("Gk Commit Id is $gk_commit_id");

    $command =
      "git --git-dir $dot_git --work-tree $model merge-base ORIG_HEAD $gk_commit_id";
    $VTMBTool->log("Invoking [$command].");
    my $lca_commit_id = `$command`;
    &trim($lca_commit_id);
    $VTMBTool->log("LCA commit id is $lca_commit_id");

    return ( $lca_commit_id, $user_commit_id );
}

sub updateRunStages {
    return if ($build_all);

#This is where I update RunStages after reading in the %dut_contexts which have been affected
    my ( $dut, $context );

    #Disabling all RunStages first
    &hashUpdate( \%RunStages, 0 );

    foreach $dut ( keys %dut_contexts ) {
        foreach $context ( keys %{ $dut_contexts{$dut} } ) {

            if ( exists $RunStages{$dut} ) {
                if ( exists $RunStages{$dut}{$context} ) {
                    $RunStages{$dut}{$context} = 1;

                }
                elsif ( ( $context eq "NONE" ) || ( $context eq "default" ) )
                {    #default is the 'Default' context for disp
                    $RunStages{$dut}{"NONE"} = 1;
                }
            }
        }
    }
}

sub BuildModels {
    my $disable_create_taskfile = shift(@_);

    # Display status and set up indentation
    $VTMBTool->indent_msg(0);
    $VTMBTool->info("Setting up Build Commands for Models");
    $VTMBTool->indent_msg(2);
    my @temp;
    my @duts;
    my $dut;
    my (
        $job_cmd,         $build_cmd,  $job_name,     $job_desc,
        $job_check,       $job_gating, $job_auto_req, $spawn_auto_req,
        $job_fcm_nb_n_nb, $job_type
    );
    my ( $fcm_session_dir, $fcm_host );
    my ( @job_dep, $dep, @job_dep_cond, $job_post_exec, @job_dep_full );
    my ($job_sim_value);
    my ($job_early_kill);
    my ( $job_nbclass, $job_nbpool, $job_nbqslot );

    #   my ($spawn_task,@job_spawn_task);
    my ($spawn_task);
    my ( @job_env, $env_vars, $env_val );
    my ($found_job) = 0;
    my ( $task_ward, $task_modelroot );
    my ($machine_delegate_group);
    my $smart = 0;

    #If it doesn't exists. Create Directory for NBFeeder Jobfiles.
    if ( !$print_commands ) {
        $VTMBTool->create_directories(
            $VTMBObj->get('MODEL') . "/GATEKEEPER/NBFeederTaskJobs" );
    }

    $VTMBTool->log(
"Creating log directory in ${workdir} - hack to fix issue with gnr 3.0.8 model/log issue \n"
    );
    if ( !-e "$workdir/log" ) {
        `mkdir -p $workdir/log`;
        `mkdir -p $workdir/bld`;
        `mkdir -p $workdir/rpt`;
    }
    # Based on Cluster Build the Simbuild Commandline Arguments.
    BUILD:foreach $build_cmd ( @{ $Models{simbuild_cmds} } ) {
      my $mail_list;
      #**********************************************************
      #Additing to run jobs if they have keyword 'MATCH' defined in
      #recipe which points to a file having setof  files - which if matches
      #with GK_FILES_CHANGED; job should be run otherwise skipped [applicable only for
      #MOCK/FILTER.FLOW-> 1. If mock/filter-? Find for keyword MATCH 2.If file exists
      #get the details of files and match with GK_FILES-CHANGED. 3. If matches,
      #then run that job otherwise skip that --
      #****************************************************************
        if ( (($GkEventType eq "MOCK") || ($GkEventType eq "FILTER")) &&  ((defined $build_cmd->{MATCH}) && (defined $ENV{'GK_FILES_CHANGED'})) ) {
                my %gk_files_list = ();
                my %match_files_list = ();
                my $match_file = $build_cmd->{MATCH};
                $VTMBTool->log("MATCH keyword found for $build_cmd->{CLUSTER}. Getting file details..\n");
                if ( !(-e $match_file ) ) {
                    $VTMBTool->log("File $match_file doesnot exists. Please update recipe with valid file. Exiting..");
                    $VTMBTool->info("File $match_file doesnot exists. Please update recipe with valid file. Exiting..");

                    exit(-1);
                }
                my $match_file_list = "cat $match_file";
                my @match_files = qw ();
                $VTMBTool->run( $match_file_list, \@match_files );
                &trim($_) for (@match_files);
                $VTMBTool->log("Reading match file lists..\n");
                if ( !scalar(@match_files) ) {
                    $VTMBTool->log("Match File $match_file is empty. Exiting..\n");
                    $VTMBTool->info("Match File $match_file is empty. Exiting..\n");

                    exit(-1);
                }
                my $gk_area = $VTMBObj->get('MODEL') . "/GATEKEEPER/" ;
                my $match_file_cp = "$cp_cmd $match_file  $gk_area";
                if ( $VTMBTool->run($match_file_cp) == 0 ) {
                    $VTMBTool->info("Successfully uploadeded $match_file to $gk_area");
                }
                else {
                    $VTMBTool->info("Error in uploading $match_file to $gk_area");
                }

                $match_files_list{'match_files'} = join("\n", @match_files);
                 my $files_changed_cmd = "cat $ENV{'GK_FILES_CHANGED'}";
                 my @files_changed = qw();
                 $VTMBTool->run( $files_changed_cmd, \@files_changed );
                 @fileschanged = @files_changed;
                 if($?) {
                    $VTMBTool->log("Unable to cat [$ENV{'GK_FILES_CHANGED'}]: $!");

                 }
                 my $num_of_files = scalar(@files_changed);
                 if( ! $num_of_files ) {
                    $VTMBTool->log("Zero ($num_of_files) files changed.");
                    $VTMBTool->log("No Jobs will be pruned");

                    return;
                 }
                 for (@files_changed) {
                     &trim($_);
                     $gk_files_list{$_}++;
                 }
                 my @filematched;
                 #matching match file list to GK files changed
                 foreach my $files (split("\n", $match_files_list{'match_files'})) {
        # Trimming space and newline
                        if ( $files =~ /^#/ ) {
                            $VTMBTool->log("Comment found in match config file - $files \n");
                            next;
                        }
	                      $files =~ s/^\s+//g;
	                      $files =~ s/\s+$//g;
                        $files =~ s/\*/\.*/g;
                        #Added to get values which needs to be replaced in match config
                        if ( defined $build_cmd->{STRING_MATCH} ) {
                            foreach my $str_rep ( keys %{ $build_cmd->{STRING_MATCH} } ) {
                                my $str_val  = $build_cmd->{STRING_MATCH}{$str_rep};
                                $files =~ s/$str_rep/$str_val/g;
                            }
                        }
                        @filematched = grep(/$files/, (keys %gk_files_list));
                        if(scalar(@filematched)) {
                            $VTMBTool->log("File matching GK_FILES_CHANGED $files:  @filematched  for  $build_cmd->{NAME} ");
                            last;#next BUILD;

                        }
                  } if (!scalar(@filematched) ){
                         $VTMBTool->log("No matching file found. Skipping $build_cmd->{NAME} ");
                         next BUILD;
                    }
        }

        # Is Cluster Defined and is there a GateKeeper Event Defined as well.
        if (
            ( $build_cmd->{CLUSTER} eq $ENV{'GK_CLUSTER'} )
            && (   ( defined $build_cmd->{$GkEventType} )
                && ( $build_cmd->{$GkEventType} eq $ENV{'GK_CLUSTER'} ) )
          )
        {
            if ( defined $build_cmd->{SMART} ) {
                $smart = $build_cmd->{SMART};
            }

            # Setup Duts array based on CLUSTER or DUTS override.
            if ( !defined $build_cmd->{DUTS} ) {
                undef @duts;
                push @duts, $build_cmd->{CLUSTER};
            }
            else {
                @duts = split( / /, $build_cmd->{DUTS} );
            }

            my $context = $build_cmd->{CMDS};

            if (defined @norun_array)
            {
                foreach my $regex (@norun_array)
                {
                      if ($context =~ /$regex/)
                      {
                             $VTMBTool->log("Skipping $build_cmd->{NAME} as $regex was added as norun\n");
                             next BUILD;
                      }

                }
            }
            chomp $context;

            if ( $context =~ /--context\s+(\S+)\s*/ ) {
                $context = $1;
            }
            elsif ( $context =~ /-c\s+(\S+)\s*/ ) {
                $context = $1;
            }
            else {
                $context = "NONE";
            }

            # Based on DUTS Create the Job Hash
          BUILDDUT: foreach $dut (@duts) {

                #Smart build job for event GkEventType
                if ( $ENV{'GK_SMART_MODE'} ) {
                    my $in_run_stages = 1;
                    if ( not $RunStages{$dut}{$context} ) {
                        $VTMBTool->info("SmartGK: Skipping DUT: $dut, CONTEXT: $context");
                        $in_run_stages = 0;
                    }
                    # Smart waiver
                    my $in_smart_waiver = 0;
                    my %sw_duts = map {$_ => 1} keys %smart_waiver_tree;
                    if ( defined $sw_duts{$dut} ) {
                        foreach my $item ( @{$smart_waiver_tree{$dut}} ){
                            if ( Compare($build_cmd, $item) ){
                                $in_smart_waiver = 1;
                            }
                        }
                    }
                    next BUILDDUT if ($in_run_stages == 0 and $in_smart_waiver == 0);

                }

                #Hack to resolve race condition in GNR 4.0.6 - HSD# 921342
                `mkdir -p $workdir/bld/$dut`;

                $job_name  = $build_cmd->{NAME};
                $job_desc  = $build_cmd->{DESC};
                $job_check = $build_cmd->{CHECK};

                $ENV{LISTNAME} = "gk" if (! defined $Models{disable_runreg_links_creation} || ($Models{disable_runreg_links_creation} == 0));

                $job_cmd = "gnr ";
                if (! defined $Models{disable_runreg_links_creation} || ($Models{disable_runreg_links_creation} == 0))
		{
                    $VTMBTool->info("disable_runreg_links_creation is either not set or 0");
		    my $workdir = `grep work_dir "$ENV{PROJ}/validation/list/gk.list"`;
                    chomp($workdir);
                    my ( $tmp, $link_path ) = split /: /, $workdir;
                    $link_path =~ s/\$PROJ\//$ENV{PROJ}\//;
                    $link_path =~ s/[\s\t\n]+//g;
                    $link_path .= "/models/";
                    $VTMBTool->run(
                        "\\rm -f '$link_path/$rid'; ln -fs '$regress_path' '$link_path/$rid'"
                    );

	           #SMADAN1 DYNAMIC LINK CREATION DUTs work_dir/models/GK (if available) to $link_path
                    if ( -e "$ENV{PROJ}/validation/list/$dut.list" ) {
                        my $dut_workdir =
                          `grep work_dir "$ENV{PROJ}/validation/list/$dut.list"`;
                        chomp($dut_workdir);
                        my ( $tmp_dut, $link_path_dut ) = split /: /, $dut_workdir;
                        $link_path_dut =~ s/\$PROJ\//$ENV{PROJ}\//;
                        $link_path_dut =~ s/[\s\t\n]+//g;
                        $link_path_dut .= "/models/GK";
                        if ( -e "$link_path_dut" ) {
                            $VTMBTool->run(
"\\rm -f '$link_path_dut/$rid'; ln -fs '$link_path/$rid' '$link_path_dut/$rid'"
                            );
                        }
                    }
		}
                $job_cmd .= $build_cmd->{CMDS} . " ";

                my ( $gnr_args, $cb_args ) = split /-- /, $job_cmd;
                $job_cmd = $gnr_args;

               #AT removed -j 10/3/2013 $job_cmd .= "-m $regress_path -d $dut -j ";
               #AT removed -m addition to commands if __MODEL__ keyword is given in recipe
               #$job_cmd .= "-m $regress_path -d $dut ";
                if ( $job_cmd =~ /__MODEL__/ ) {
                    $job_cmd .= " -d $dut ";
                }
                else {

                    # FIX ME: Left this in there so the existing turnins go thru
                    # eventually should be removed once the recipe is clean and
                    # contains MODEL for all commands that need it.
                    $job_cmd .= "-m $regress_path -d $dut ";
                }

                # AT 12/13/2013 now add the call back args in
                if ($cb_args) {
                    $job_cmd .= "-- $cb_args";
                }

                ## Substitute 'special' keywords for runtime derived
                ## values. Where possible the keywords should be
                ## '__<keyword>__', to reduce the risk that they occur
                ## naturally.
                my %substitutions = (
                    'NAME'        => $dut,
                    '__MODEL__'   => $ENV{'MODEL'},
                    '__NBQSLOT__' => $ENV{'NBQSLOT'},
                    '__NBPOOL__'  => $ENV{'NBPOOL'},
                );

                while ( my ( $key, $value ) = each(%substitutions) ) {
                    $job_cmd  =~ s/$key/$value/g;
                    $job_name =~ s/$key/$value/g;
                    $job_desc =~ s/$key/$value/g;
                }

                #DANGLE CHECK
                my $dangle_limit;
                my $cxt;

                  if ( $build_cmd->{CMDS} =~ /\-\-context\s+(\w+)\s*/ ){
                    $cxt = $1;
                  }elsif($build_cmd->{CMDS} =~ /\-c\s+(\w+)\s*/){
                    $cxt = $1;
                  }

                if ( $build_cmd->{CLUSTER} eq "$ENV{GK_CLUSTER}" ) {
                    if (   ( ref( $Models{dangle_limit} ) eq "HASH" )
                        && ( defined $Models{dangle_limit}->{$cxt} ) )
                    {
                        $dangle_limit = $Models{dangle_limit}->{$cxt};
                    }
                    else {
                        $dangle_limit = $Models{dangle_limit};
                    }
                }

                if ( $Models{dangle_check_enable} == 1 ) {

                    if (   ( $dut eq "gt" )
                        && ( $build_cmd->{CMDS} =~ /gen_rtl/ ) )
                    {
                        $job_cmd .= "-- --dangle-limit $dangle_limit ";
                    }
                }

                # Perform Replace on NAME
                $job_cmd  =~ s/NAME/$dut/g;
                $job_name =~ s/NAME/$dut/g;
                $job_desc =~ s/NAME/$dut/g;

                # Perform Replace on <REPO_ROOT>
                $job_cmd =~ s/<REPO_ROOT>/$ENV{'MODEL'}/g;
                $job_cmd =~ s/(\s|^)MODEL(\/|\s|$)/$1$ENV{MODEL}$2/g;

                # Handle Dependency if it exists.
                if ( defined $build_cmd->{DEPENDENCY} ) {
                    undef @job_dep;
                    undef @job_dep_cond;
                    undef @job_dep_full;
                    my $job_dep_full_tmp;

                    foreach my $dep ( keys %{ $build_cmd->{DEPENDENCY} } ) {
                        $job_dep_full_tmp = $dep;
                        $job_dep_full_tmp =~ s/NAME/$dut/g;
                        if ( $build_cmd->{DEPENDENCY}{$dep} eq "" ) {
                            push @job_dep_cond, "Success";    # default value is success
                            push @job_dep_full, "$job_dep_full_tmp : Success";
                        }
                        else {
                            push @job_dep_cond, "$build_cmd->{DEPENDENCY}{$dep}";
                            push @job_dep_full,
                              "$job_dep_full_tmp : $build_cmd->{DEPENDENCY}{$dep}";
                        }

                        # Create Dependency and append Process Prefix to all.
                        $dep =~ s/NAME/$dut/g;
                        push @job_dep, "$VTMBObj->{TASK_PREFIX}.$dep";

                    }
                }
                else {
                    undef @job_dep;
                    undef @job_dep_cond;
                    undef @job_dep_full;
                }

                # Handle Job Simulation Value if it exists
                $job_sim_value =
                  ( defined $build_cmd->{SIM_VALUE} )
                  ? $build_cmd->{SIM_VALUE}
                  : undef $job_sim_value;

                # Old Code Remove by 3/1/2011
                # Handle a Job with a GATING override
                #$job_gating = (defined $build_cmd->{GATING}) ? $build_cmd->{GATING} : 1;

                #New Code
                # Gating can now handle GK Eventtype override.
                $job_gating =
                  ( defined $build_cmd->{GATING} )
                  ? &process_cfg_var( \$build_cmd, "GATING", $GkEventType )
                  : 1;

                # Handle Early Kill
                $job_early_kill =
                  ( defined $build_cmd->{EARLY_KILL} ) ? $build_cmd->{EARLY_KILL} : 0;

                # Handle Forced Early Kill by overriding job hash.
                if (
                    defined $Models{force_early_kill_build}{ $ENV{'GK_CLUSTER'} }
                    { $ENV{'GK_EVENTTYPE'} } )
                {
                    $job_early_kill = 1;
                }

# Handle Netbatch Configuration Overrides
# Old Code - Delete by August 1, 2010
#$job_nbpool  = ($ENV{'GK_MOCK_NBPOOL'}  && ($GkEventType eq "MOCK")) ? $ENV{'GK_MOCK_NBPOOL'}  : (defined $build_cmd->{NBPOOL})  ? $build_cmd->{NBPOOL}  : $ENV{'NBPOOL'};
#$job_nbclass = ($ENV{'GK_MOCK_NBCLASS'} && ($GkEventType eq "MOCK")) ? $ENV{'GK_MOCK_NBCLASS'} : (defined $build_cmd->{NBCLASS}) ? $build_cmd->{NBCLASS} : $ENV{'NBCLASS'};
#$job_nbqslot = ($ENV{'GK_MOCK_NBQSLOT'} && ($GkEventType eq "MOCK")) ? $ENV{'GK_MOCK_NBQSLOT'} : (defined $build_cmd->{NBQSLOT}) ? $build_cmd->{NBQSLOT} : $ENV{'NBQSLOT'};
# New Code

                ( $job_nbpool, $job_nbclass, $job_nbqslot ) = determine_nb_configuration(
                    $build_cmd,              $job_name,
                    $GkEventType,            $ENV{'GK_MOCK_NBPOOL'},
                    $ENV{'GK_MOCK_NBCLASS'}, $ENV{'GK_MOCK_NBQSLOT'},
                    $ENV{'NBPOOL'},          $ENV{'NBCLASS'},
                    $ENV{'NBQSLOT'}
                );

                # Handle Job Type
                $job_type = &set_job_type_if_defined( $job_name, \%Models, \$build_cmd );

                #if(defined $build_cmd->{JOB_TYPE})
                # {
                #   $job_type = $build_cmd->{JOB_TYPE};
                # }
                #else
                # {
                #   undef $job_type;
                # }

                # Handle Auto Requeue Override
                if ( defined $build_cmd->{AUTO_REQ} ) {
                    $job_auto_req = $build_cmd->{AUTO_REQ};
                }
                else {
                    undef $job_auto_req;
                }

                # Handle Auto Requeue Override
                if ( defined $build_cmd->{SPAWN_AUTO_REQ} ) {
                    $spawn_auto_req = $build_cmd->{SPAWN_AUTO_REQ};
                }
                else {
                    undef $spawn_auto_req;
                }

                ## Check to see if SPAWN Task is set.
                my ( @spawn_task_desc, $spawn_desc, @job_spawn_task, $spawn_task_name );
                if ( defined $build_cmd->{SPAWN_TASK} ) {
                    my $spawn_task_index = 0;
                    foreach $spawn_task ( @{ $build_cmd->{SPAWN_TASK} } ) {
                        $spawn_task_name = $spawn_task;
                        $job_cmd         =~ s/GK_DUT/$dut/;
                        $job_cmd         =~ s/GK_TASK_PREFIX/$ENV{'GK_TASK_PREFIX'}/;
                        $job_cmd         =~ s/GK_TASK_AREA/$ENV{'GK_TASK_AREA'}/g;
                        $job_cmd         =~ s/GK_NBPOOL/$job_nbpool/g;
                        $job_cmd         =~ s/GK_NBCLASS/$job_nbclass/g;
                        $job_cmd         =~ s/GK_NBQSLOT/$job_nbqslot/g;
                        $spawn_task_name =~ s/NAME/$dut/g;
                        push @job_spawn_task,
                          "$ENV{'GK_TASK_AREA'}/$ENV{'GK_TASK_PREFIX'}.$spawn_task_name";
                        $spawn_desc = $build_cmd->{SPAWN_DESC}->[$spawn_task_index];
                        $spawn_desc =~ s/NAME/$dut/g;
                        push @spawn_task_desc, $spawn_desc;
                        $spawn_task_index++;
                    }
                }
                else {
                    undef @job_spawn_task;
                }

                # Check if this is a Netbatch in Netbatch job.
                if ( defined $build_cmd->{FCM_NB_N_NB} ) {

                    # Create FCM Server Directory if it doesn't exist
                    if ( defined $Models{fcm_session_dir}{ $ENV{'GK_EVENTTYPE'} } ) {
                        $fcm_session_dir =
                          $Models{fcm_session_dir}{ $ENV{'GK_EVENTTYPE'} }
                          . "/$ENV{'USER'}";
                        $VTMBTool->info(
"FCM Session Dir is defined for $job_name, using $fcm_session_dir"
                        );
                    }
                    elsif (( defined $Models{fcm_session_dir} )
                        && ( ref $Models{fcm_session_dir} ne 'HASH' ) )
                    {
                        $fcm_session_dir = $Models{fcm_session_dir} . "/$ENV{'USER'}";
                        $VTMBTool->info(
"FCM Session Dir is defined for $job_name, using $fcm_session_dir"
                        );
                    }
                    else {
                        $fcm_session_dir = $ENV{'MODEL'} . "/GATEKEEPER/fcm_session_dir";
                        $VTMBTool->info(
"FCM Session Dir is not defined for $job_name, using $fcm_session_dir"
                        );
                    }
                    $VTMBTool->create_directories("$fcm_session_dir");
                    $ENV{'GK_FCM_SESSION_DIR'} = $fcm_session_dir;

                    # Set FCM Server HOST
                    if ( defined $Models{fcm_host}{ $ENV{'GK_EVENTTYPE'} } ) {
                        $fcm_host = $Models{fcm_host}{ $ENV{'GK_EVENTTYPE'} };
                        $VTMBTool->info(
                            "FCM HOST is defined for $job_name, using $fcm_host");
                    }
                    elsif (( defined $Models{fcm_host} )
                        && ( ref $Models{fcm_host} ne 'HASH' ) )
                    {
                        $fcm_host = $Models{fcm_host};
                        $VTMBTool->info(
                            "FCM HOST is defined for $job_name, using $fcm_host");
                    }
                    else {
                        $fcm_host = $ENV{'HOST'};
                        $VTMBTool->info(
                            "FCM HOST is defined for $job_name, using $fcm_host");
                    }

                    # Setup the Job
                    $job_fcm_nb_n_nb = $build_cmd->{FCM_NB_N_NB};
                    $job_cmd =~ s/FCM_ID/$ENV{'GK_TASK_PREFIX'}.$job_name/;
                    $job_cmd =~ s/FCM_SESSION_DIR/$fcm_session_dir/;
                    $job_cmd .= " -net -P $job_nbpool -C '$job_nbclass' -Q $job_nbqslot";

                }
                else {
                    undef $job_fcm_nb_n_nb;
                }

                # Check to See if Job Contains Post Exec Commands.
                if ( defined $build_cmd->{JOB_POST_EXEC} ) {
                    $job_post_exec =
                      &process_cfg_var( \$build_cmd, "JOB_POST_EXEC", $GkEventType );
                    if ( defined $job_post_exec ) {
                        $job_post_exec =~ s/(\s|^)MODEL(\/|\s|$)/$1$ENV{MODEL}$2/g;
                        $job_post_exec =~ s/PROGRAM_DIR/$ProgramDir/;
                        $job_post_exec =~ s/DUT/$dut/g;
                        $job_post_exec =~ s/NAME/$dut/g;
                        if ( defined $build_cmd->{FCM_NB_N_NB} ) {
                            $job_post_exec =~ s/FCM_ID/$ENV{'GK_TASK_PREFIX'}.$job_name/;
                        }
                    }
                }
                else {
                    undef $job_post_exec;
                }

                # Check to see if Job Contains Environment Settings
                undef @job_env
                  ; # Undef this variable so it doesn't get appended with everything previous.
                if ( defined $build_cmd->{JOB_ENV_SET} ) {
                    foreach my $env_set ( keys %{ $build_cmd->{JOB_ENV_SET} } ) {
                        $env_vars = $env_set;
                        $env_val  = $build_cmd->{JOB_ENV_SET}{$env_set};
                        $env_vars =~ s/NAME/$dut/g;
                        $env_val  =~ s/NAME/$dut/g;
                        $env_val  =~ s/GK_TASK_PREFIX/$ENV{'GK_TASK_PREFIX'}/g;
                        push @job_env, "set:$env_vars:$env_val";
                    }
                }

                push @job_env, "set:GK_STAGE_NAME:$job_name";

# Set a dependency for use by simregress task dependency name.
# As of June 30, 2009, this hash is obsolete, it can be removed once GenerateRegression subroutine is deleted.
                $all_job_names{$job_name} = $job_name;

                # Add Task Name to Hash which maps job names to Tasks
                $job_2_task_names{$job_name} = "$VTMBObj->{TASK_PREFIX}.$job_name";

                $VTMBTool->info("Adding Build String for $job_name");

# To support Clone in Clone Update, WORKAREA and MODELROOT can be overridden with GkUtils.
                if ( !defined $build_cmd->{WORKAREA_EXTD} ) {
                    $task_ward = $VTMBObj->get('MODEL') . "/GATEKEEPER/NBFeederTaskJobs";
                    $task_modelroot = $VTMBObj->get('MODEL');
                }
                else {
                    $task_ward =
                        $VTMBObj->get('MODEL') . "/"
                      . $build_cmd->{WORKAREA_EXTD}
                      . "/GATEKEEPER/NBFeederTaskJobs";
                    $task_modelroot =
                      $VTMBObj->get('MODEL') . "/" . $build_cmd->{WORKAREA_EXTD};
                }

                # Add NBfeeder Machine Delegate Groups if needed.
                if (   ( defined $build_cmd->{DELEGATE_GROUP} )
                    && ( $GkEventType eq "MOCK" ) )
                {

                    # Determine if specified Machine Delegate Group is as follows.
                    # If 1, Delegate group equals $HOST.
                    # If List Delegate group equals the list of machines specified.

                    if ( ref $build_cmd->{DELEGATE_GROUP} eq 'ARRAY' ) {
                        $VTMBTool->error(
"Support for DELEGATE_GROUP as Array is not support, please set to Scalar containing a list of machine, or 1 to use the current HOST."
                        );

#$machine_delegate_group = join(" ",@{$build_cmd->{DELEGATE_GROUP}});
#$VTMBTool->info(" Job $build_cmd->{NAME} configured to run on Machine Delegate Group Array Override Specified: $machine_delegate_group ");
                    }
                    elsif ( ref $build_cmd->{DELEGATE_GROUP} eq 'HASH' ) {
                        $VTMBTool->error(
"Support for DELEGATE_GROUP as HASH is not support, please set to ARRAY containing a list of machine, or 1 to use the current HOST."
                        );
                    }
                    else {
                        if ( $build_cmd->{DELEGATE_GROUP} eq 1 ) {
                            $machine_delegate_group = $ENV{'HOST'};
                            $VTMBTool->info(
" Job $build_cmd->{NAME} configured to run on Machine Delegate Group Scalar Override on Host: $ENV{'HOST'} "
                            );
                        }
                        else {
                            $machine_delegate_group = $build_cmd->{DELEGATE_GROUP};
                            $VTMBTool->info(
" Job $build_cmd->{NAME} configured to run on Delegate Group Specified as List: $machine_delegate_group"
                            );
                        }
                    }
                }
                else {
                    undef $machine_delegate_group;
                }

                if (defined $build_cmd->{SEND_MAIL}) {
                  $mail_list = $build_cmd->{SEND_MAIL};
                }

                # Create JOB Object
                $VTMBJob = new VTMBJob(
                    DUT              => $dut,
                    NAME             => $job_name,
                    CMDS             => $job_cmd,
                    DESC             => $job_desc,
                    DEPENDENCY       => [@job_dep],
                    DEPENDENCY_FULL  => [@job_dep_full],
                    DEP_COND         => [@job_dep_cond],
                    WORKAREA         => $task_ward,
                    MODEL            => $task_modelroot,
                    CHECK            => $job_check,
                    SEND_MAIL        => $mail_list,
                    SIM_VALUE        => $job_sim_value,
                    GATING           => $job_gating,
                    EARLY_KILL       => $job_early_kill,
                    NBCLASS          => $job_nbclass,
                    NBPOOL           => $job_nbpool,
                    NBQSLOT          => $job_nbqslot,
                    SPAWN_TASK       => [@job_spawn_task],
                    SPAWN_DESC       => [@spawn_task_desc],
                    AUTO_REQ         => $job_auto_req,
                    JOB_POST_EXEC    => $job_post_exec,
                    SPAWN_AUTO_REQ   => $spawn_auto_req,
                    FCM_NB_N_NB      => $job_fcm_nb_n_nb,
                    JOB_ENV          => [@job_env],
                    JOB_TYPE         => $job_type,
                    DELEGATE_GROUP   => $machine_delegate_group,
                    DISABLE_NB_CHECK => $disable_nb_check,
                    SMART            => $smart,
                  )
                  or die
                  "Error Initializing VTMBJob Object. Report this bug to GK Owner\n";

                # Check Job NB Settings to ensure this is a valid Netbatch Configuration.
                # If this is a print commands invocation, turn error into warning.
                if (
                    !defined $netbatch_settings{$job_nbpool}{$job_nbclass}{$job_nbqslot} )
                {
                    $VTMBJob->check_netbatch_settings( $VTMBTool, $print_commands,
                        \%netbatch_settings );

    # Commented out NBFlow team recommendation because it doesn't work on virtual pools.
    # $VTMBJob->validate_netbatch_settings($VTMBTool,$print_commands,\%netbatch_settings);
    # Add the job to the HASH for record keeping purposes.
                    push @{ $netbatch_settings{$job_nbpool}{$job_nbclass}{$job_nbqslot}
                          {JOBS} }, $VTMBJob->{NAME};
                }
                else {

                    # Add the job to the HASH for record keeping purposes.
                    push @{ $netbatch_settings{$job_nbpool}{$job_nbclass}{$job_nbqslot}
                          {JOBS} }, $VTMBJob->{NAME};
                }

               # If Job this gk-utils invocation is not print commmands, create task file.
                if ( !$print_commands ) {

                    #Create NBFeeder Task File
                    #&create_job_file($VTMBJob);
                    if ( !$disable_create_taskfile ) {
                        if ( defined $build_cmd->{TIMEOUT} ) {
                            $VTMBJob->create_taskfile( $VTMBObj, $build_cmd->{TIMEOUT} );
                        }
                        else {
                            $VTMBJob->create_taskfile( $VTMBObj,
                                $Models{timeout}{build} );
                        }
                    }
                }

                # Add Jobs to JobsArray & JobsMapArray
                push @temp, $VTMBJob;
                my $jobs_map = $ENV{'GK_TASK_PREFIX'} . "." . $VTMBJob->{NAME};
                $VTMBJobsMap{$jobs_map} = $VTMBJob;
                $found_job++;
            }
        }
    }

    # Error if Build Options are not Found unless empty_recipe is defined for this cluster
    if ( !$found_job ) {
        if ( exists $Models{empty_recipe}{ $ENV{'GK_CLUSTER'} }
            && $Models{empty_recipe}{ $ENV{'GK_CLUSTER'} } == 1 )
        {
            $VTMBTool->info(
                "Cluster $ENV{'GK_CLUSTER'} contains no build/regress recipe. Exiting..."
            );
            exit(0);
        }

#      $VTMBTool->error("No Build Options found for $ENV{'GK_CLUSTER'} as $ENV{'GK_EVENTTYPE'}. Contact GK Owner");
    }

    # Terminate on errors
    $VTMBTool->check_errors();

    #Return Jobs
    return @temp;
}

#-------------------------------------------------------------------------------
# GeneralJobs()
#   Create jobs for anything that is non regression in nature, even supports
#    simbuild jobs. Had I written this subroutine first, BuildModels would not
#    exists, at some point in time, BuildModels will be removed, perhaps gk-utils2.
#-------------------------------------------------------------------------------
sub GeneralJobs {
    my $hash_key                = shift(@_);
    my $disable_create_taskfile = shift(@_);

    # Display status and set up indentation
    $VTMBTool->indent_msg(0);
    $VTMBTool->info("Setting up General Commands");
    $VTMBTool->indent_msg(2);
    my @temp;
    my ( @duts, @job_list );
    my $dut;
    my (
        $job_cmd,      $build_cmd,     $job_name,
        $job_desc,     $job_check,     $job_gating,
        $job_pre_exec, $job_post_exec, $job_create_dir
    );
    my ( @job_dep, $dep, @job_dep_cond, @job_dep_full );
    my ( $job_early_kill, $nbjob_opts );
    my ( $job_nbclass,    $job_nbpool, $job_nbqslot, $job_type );
    my ( $spawn_task,     @job_spawn_task );
    my ( @job_env, $env_vars, $env_val );
    my ($found_job) = 0;
    my ( $task_ward, $task_modelroot );
    my ($machine_delegate_group);
    my @jobs_list;
    my ($task_auto_req);
    my ( $cmd, @cmd_output );
    my $release_model = basename( $ENV{'MODEL'} );
    my ( $env_args, @env_cmd_string, $env_file, $env_source_cmd, @env_source_results,
        $csh_file, @env_cmds );
    my ($allow_empty_jobfile);
    my $smart = 0;
    my $general_cmd_mail_list;

    # Create Directory if it does not exist
    if ( !$print_commands ) {
        $VTMBTool->create_directories(
            $VTMBObj->get('MODEL') . "/GATEKEEPER/NBFeederTaskJobs" );
    }

    # Based on Cluster Build the Simbuild Commandline Arguments.
    OUTFOR: foreach my $general_cmd ( @{ $Models{$hash_key} } ) {
        if (( ($GkEventType eq "MOCK") || ($GkEventType eq "FILTER") ) && ( (defined $general_cmd->{MATCH}) && (defined $ENV{'GK_FILES_CHANGED'}) ) ){
                my %gk_files_list = ();
                my %match_files_list = ();
                my $match_file = $general_cmd->{MATCH};
                $VTMBTool->log("MATCH keyword found for $general_cmd->{CLUSTER}. Getting file details..\n");
                if ( !(-e $match_file ) ) {
                    $VTMBTool->log("File $match_file doesnot exists. Please update recipe with valid file. Exiting..");
                    $VTMBTool->info("File $match_file doesnot exists. Please update recipe with valid file. Exiting..");
                    exit(-1);
                }
                my $match_file_list = "cat $match_file";
                my @match_files = qw ();
                $VTMBTool->run( $match_file_list, \@match_files );
                $VTMBTool->log("Reading match file lists..\n");
                if ( !scalar(@match_files) ) {
                    $VTMBTool->log("Match File $match_file is empty. Exiting..\n");
                    $VTMBTool->info("Match File $match_file is empty. Exiting..\n");
                    exit(-1);
                }
			    my $gk_area = $VTMBObj->get('MODEL') . "/GATEKEEPER/" ;
                my $match_file_cp = "$cp_cmd $match_file  $gk_area";
                if ( $VTMBTool->run($match_file_cp) == 0 ) {
                    $VTMBTool->info("Successfully uploadeded $match_file to $gk_area");
                }
                else {
                    $VTMBTool->info("Error in uploading $match_file to $gk_area");
                }
                $match_files_list{'match_files'} = join("\n", @match_files);
                my $files_changed_cmd = "cat $ENV{'GK_FILES_CHANGED'}";
                 my @files_changed = qw();
                 $VTMBTool->run( $files_changed_cmd, \@files_changed );
                 @fileschanged = @files_changed;
                 if($?) {
                    $VTMBTool->log("Unable to cat [$ENV{'GK_FILES_CHANGED'}]: $!");

                 }
                 my $num_of_files = scalar(@files_changed);
                 if( ! $num_of_files ) {
                    $VTMBTool->log("Zero ($num_of_files) files changed.");
                    $VTMBTool->log("No Jobs will be pruned");

                    return;
                 }
                 $gk_files_list{$_}++ for (@files_changed);
                 my @filematched;
                 #matching prune file list to GK files changed
                 foreach my $files (split("\n", $match_files_list{'match_files'})) {
        # Trimming space and newline
                      if ( $files =~ /^#/ ) {
                          $VTMBTool->log("Comment found in match config file - $files \n");
                          next;
                      }
                      $files =~ s/^\s+//g;
                      $files =~ s/\s+$//g;
                      $files =~ s/\*/\.*/g;
                      if ( defined $general_cmd->{STRING_MATCH} ) {
                            foreach my $str_rep ( keys %{ $general_cmd->{STRING_MATCH} } ) {
                                my $str_val  = $general_cmd->{STRING_MATCH}{$str_rep};
                                $files =~ s/$str_rep/$str_val/g;
                            }
                      }
                      @filematched = grep(/$files/, (keys %gk_files_list));
                      if(scalar (@filematched)) {
                         $VTMBTool->log("File matching GK_FILES_CHANGED $files:  @filematched for $general_cmd->{NAME}  ");                 last;#next OUTFOR ;

                      }
                  }
                  if (!scalar(@filematched) ){
                         $VTMBTool->log("No matching file found. Skipping $general_cmd->{NAME} ");
                         next OUTFOR;
                    }
        }

        # Is Cluster Defined and is there a GateKeeper Event Defined as well.
        if (
            ( $general_cmd->{CLUSTER} eq $ENV{'GK_CLUSTER'} )
            && (   ( defined $general_cmd->{$GkEventType} )
                && ( $general_cmd->{$GkEventType} eq $ENV{'GK_CLUSTER'} ) )
          )
        {
            if ( defined $general_cmd->{SMART} ) {
                $smart = $general_cmd->{SMART};
            }

            # Setup Duts array based on CLUSTER or DUTS override.
            if ( !defined $general_cmd->{DUTS} && !defined $general_cmd->{LIST} ) {
                undef @duts;
                push @duts, $general_cmd->{CLUSTER};
            }
            elsif ( defined $general_cmd->{DUTS} && !defined $general_cmd->{LIST} ) {
                @duts = split( / /, $general_cmd->{DUTS} );
            }
            elsif ( !defined $general_cmd->{DUTS} && defined $general_cmd->{LIST} ) {
                @jobs_list = split( / /, $general_cmd->{LIST} );
                $VTMBTool->error("Illegal Condition, List defined without DUTS");
            }
            elsif ( defined $general_cmd->{DUTS} && defined $general_cmd->{LIST} ) {
                @duts      = split( / /, $general_cmd->{DUTS} );
                @jobs_list = split( / /, $general_cmd->{LIST} );
            }
            else {
                $VTMBTool->error("Illegal Condition, Should never get here");
            }

            # Check for Error and Terminate
            $VTMBTool->check_errors();

            # Based on DUTS Create the Job Hash
            foreach $dut (@duts) {
                if ( defined $Models{DutAlias}{$dut} ) {
                    $VTMBTool->info(
                        "DutAlias defined,  mapping for $dut -> $Models{DutAlias}{$dut}");
                }
                else {
                    $VTMBTool->info("Not DutAlias defined for $dut");
                }

                # Smart waiver
                my %sw_duts = map {$_ => 1} keys %smart_waiver_tree;
                if ( $ENV{'GK_SMART_MODE'} and defined $sw_duts{$dut} ) {
                    my $match_found = 0;
                    foreach my $item ( @{$smart_waiver_tree{$dut}} ){
                        if ( Compare($general_cmd, $item) ){
                            $match_found = 1;
                        }
                    }
                    next OUTFOR if ($match_found == 0);
                }

                # Setup job_name, job_desc, job_cmd, job_check, job_create_dir
                $job_name  = $general_cmd->{NAME};
                $job_desc  = $general_cmd->{DESC};
                $job_check = $general_cmd->{CHECK};
                $job_cmd   = $general_cmd->{CMDS} . " ";
                if (($job_cmd =~ /fact\.pl/) && ($run_fact == 0))
                {
                       $VTMBTool->log("Skipping $job_name as runFACT is $run_fact\n");
                       next;
                }
                if (defined @norun_array)
                {
                    foreach my $regex (@norun_array)
                    {
                          if ($job_cmd =~ /$regex/)
                          {
                                 $VTMBTool->log("Skipping $job_name as $regex was added as norun\n");
                                 next OUTFOR;
                          }

                    }
                }
 # Perform Search & Replace on supported wildcards <REPO_ROOT>, <DUT>, <JOB_NAME>, <MODEL>
                $job_name =~ s/<DUT>/$dut/g;
                $job_desc =~ s/<DUT>/$dut/g;

                $job_cmd =~ s/<DUT>/$dut/g;
                $job_cmd =~ s/<REPO_ROOT>/$ENV{'MODEL'}/g;
                $job_cmd =~ s/<MODEL>/$ENV{'MODEL'}/g;
                $job_cmd =~ s/<JOB_NAME>/$job_name/g;
                $job_cmd =~ s/<PROGRAM_DIR>/$ProgramDir/g;
                $job_cmd =~ s/RELEASE_MODEL/$release_model/g;
                $job_cmd =~ s/(\s|^)MODEL(\/|\s|$)/$1$ENV{MODEL}$2/g;

                # Handle case where Function call may be a wildcard
                if ( defined $general_cmd->{EVAL} ) {
                    $cmd = $general_cmd->{EVAL};
                    $VTMBTool->run( $cmd, \@cmd_output );
                    chomp( $cmd_output[-1] );
                    $job_cmd =~ s/<EVAL>/$cmd_output[-1]/;
                }

                # Get NBJob Option if they are defined
                if ( defined $general_cmd->{NBJOB_OPTS} ) {
                    $nbjob_opts = $general_cmd->{NBJOB_OPTS};
                }
                else {
                    undef $nbjob_opts;
                }

                # Get NBTask Submission Options if they are defined.
                if ( defined $general_cmd->{AUTO_REQ} ) {
                    $task_auto_req = $general_cmd->{AUTO_REQ};
                }
                else {
                    undef $task_auto_req;
                }

                # Create Dirs if needed.
                if ( defined $general_cmd->{CREATE_DIR} ) {
                    $job_create_dir = $general_cmd->{CREATE_DIR};
                    $job_create_dir =~ s/<DUT>/$dut/g;
                    $job_create_dir =~ s/<REPO_ROOT>/$ENV{'MODEL'}/g;
                    $job_create_dir =~ s/<MODEL>/$ENV{'MODEL'}/g;
                    $job_create_dir =~ s/<JOB_NAME>/$job_name/g;

                    $VTMBTool->info(
                        " Creating directory for job :$job_name : $job_create_dir");
                    $VTMBTool->create_directories("$job_create_dir")
                      if ( ~$print_commands );
                }

                #            Commented out Old Wildcards for new formalized wildcards.
                #            # $job_cmd .= "-logprefix $general_cmd->{NAME}.";

                #             $job_cmd =~ s/RELEASE_MODEL/$release_model/g;
                #             $job_cmd =~ s/MODEL/$ENV{'MODEL'}/g;
                #             # Perform Replace on NAME
                #             $job_cmd  =~ s/NAME/$dut/g;
                #             $job_name =~ s/NAME/$dut/g;
                #             $job_desc =~ s/NAME/$dut/g;
                #

                #             # Perform Replace based on GK_TASK_PREFIX & GK_CLUSTER
                #             $job_cmd  =~ s/GK_TASK_PREFIX/$ENV{'GK_TASK_PREFIX'}/g;
                #             $job_cmd  =~ s/GK_CLUSTER/$ENV{'GK_CLUSTER'}/g;

                #             # Perform Replace on PROGRAM_DIR
                #             $job_cmd =~ s/PROGRAM_DIR/$ProgramDir/;
                # Perform Replacement on GK_TASK_PREFIX
                $job_cmd =~ s/<GK_TASK_PREFIX>/$ENV{'GK_TASK_PREFIX'}/g;

                # Handle Dependency if it exists.
                if ( defined $general_cmd->{DEPENDENCY} ) {
                    undef @job_dep;
                    undef @job_dep_cond;
                    undef @job_dep_full;
                    my $job_dep_full_tmp;
                    foreach $dep ( keys %{ $general_cmd->{DEPENDENCY} } ) {
                        $job_dep_full_tmp = $dep;

                        # $job_dep_full_tmp =~ s/NAME/$dut/g;
                        $job_dep_full_tmp =~ s/<DUT>/$dut/g;
                        if ( $general_cmd->{DEPENDENCY}{$dep} eq "" ) {
                            push @job_dep_cond, "Success";    # default value is success
                            push @job_dep_full, "$job_dep_full_tmp : Success";
                        }
                        else {
                            push @job_dep_cond, "$general_cmd->{DEPENDENCY}{$dep}";
                            push @job_dep_full,
                              "$job_dep_full_tmp : $build_cmd->{DEPENDENCY}{$dep}";
                        }

                        # Create Dependency and append Process Prefix to all.
                        # $dep  =~ s/NAME/$dut/g;
                        $dep =~ s/<DUT>/$dut/g;
                        push @job_dep, "$VTMBObj->{TASK_PREFIX}.$dep";
                    }
                }
                else {
                    undef @job_dep;
                    undef @job_dep_cond;
                    undef @job_dep_full;
                }

            # Old Code Remove by 3/1/2011
            # Handle a Job with a GATING override
            # $job_gating = (defined $general_cmd->{GATING}) ? $general_cmd->{GATING} : 1;

                #New Code
                # Gating can now handle GK Eventtype override.
                $job_gating =
                  ( defined $general_cmd->{GATING} )
                  ? &process_cfg_var( \$general_cmd, "GATING", $GkEventType )
                  : 1;

                # Handle Early Kill
                $job_early_kill =
                  ( defined $general_cmd->{EARLY_KILL} ) ? $general_cmd->{EARLY_KILL} : 0;

# Handle Netbatch Configuration Overrides
# Old Code Delete August 1,2010
#$job_nbpool  = ($ENV{'GK_MOCK_NBPOOL'}  && ($GkEventType eq "MOCK")) ? $ENV{'GK_MOCK_NBPOOL'}  : (defined $general_cmd->{NBPOOL})  ? $general_cmd->{NBPOOL}  : $ENV{'NBPOOL'};
#$job_nbclass = ($ENV{'GK_MOCK_NBCLASS'} && ($GkEventType eq "MOCK")) ? $ENV{'GK_MOCK_NBCLASS'} : (defined $general_cmd->{NBCLASS}) ? $general_cmd->{NBCLASS} : $ENV{'NBCLASS'};
#$job_nbqslot = ($ENV{'GK_MOCK_NBQSLOT'} && ($GkEventType eq "MOCK")) ? $ENV{'GK_MOCK_NBQSLOT'} : (defined $general_cmd->{NBQSLOT}) ? $general_cmd->{NBQSLOT} : $ENV{'NBQSLOT'};
                ( $job_nbpool, $job_nbclass, $job_nbqslot ) = determine_nb_configuration(
                    $general_cmd,            $job_name,
                    $GkEventType,            $ENV{'GK_MOCK_NBPOOL'},
                    $ENV{'GK_MOCK_NBCLASS'}, $ENV{'GK_MOCK_NBQSLOT'},
                    $ENV{'NBPOOL'},          $ENV{'NBCLASS'},
                    $ENV{'NBQSLOT'}
                );

            # Old Style
            # Now that NBClass,NBPool,and NBQslot are now, handle Wildcards if any exists.
            #$job_cmd =~ s/GK_NBPOOL/$job_nbpool/g;
            #$job_cmd =~ s/GK_NBCLASS/$job_nbclass/g;
            #$job_cmd =~ s/GK_NBQSLOT/$job_nbqslot/g;

                # New Style for NB Wildcards
                $job_cmd =~ s/<NBPOOL>/$job_nbpool/g;
                $job_cmd =~ s/<NBCLASS>/$job_nbclass/g;
                $job_cmd =~ s/<NBQSLOT>/$job_nbqslot/g;

                # Handle Job Type
                $job_type =
                  &set_job_type_if_defined( $job_name, \%Models, \$general_cmd );

                #if(defined $general_cmd->{JOB_TYPE})
                # {
                #   $job_type = $general_cmd->{JOB_TYPE};
                # }
                #else
                # {
                #   undef $job_type;
                # }

                # Handle CAMA Enabling.
                if ( defined $ENV{'RTL_PROJ_TOOLS'} ) {
                    $job_cmd =~ s/RTL_PROJ_TOOLS/$ENV{'RTL_PROJ_TOOLS'}/;
                }
                if ( defined $ENV{'RTL_PROJ_BIN'} ) {
                    $job_cmd =~ s/RTL_PROJ_BIN/$ENV{'RTL_PROJ_BIN'}/;
                }

  # DELETE not needed.
  #          if(defined $ENV{'CAMA_MODEL_CACHING_DISK'})
  #           {
  #             $job_cmd =~ s/CAMA_MODEL_CACHING_DISK/$ENV{'CAMA_MODEL_CACHING_DISK'}/;
  #             $job_cmd =~ s/CACHE_DUT/$Models{Cluster2Dut}{$dut}/;
  #             if((defined $general_cmd->{BIT_MODE}) && ($general_cmd->{BIT_MODE} == 64))
  #              {
  #                $job_cmd =~ s/BIT_MODE/$general_cmd->{BIT_MODE}/;
  #              }
  #             else
  #              {
  #                $job_cmd =~ s/BIT_MODE/32/;
  #              }
  #           }
  # Handle any remaining DUT whildcares in job_cmd
                $job_cmd =~ s/DUT/$dut/g;

                # Check to See if Job Contains Post Exec Commands.
                if ( defined $general_cmd->{JOB_POST_EXEC} ) {
                    $job_post_exec =
                      &process_cfg_var( \$general_cmd, "JOB_POST_EXEC", $GkEventType );
                    if ( defined $job_post_exec ) {
                        $job_post_exec =~ s/(\s|^)MODEL(\/|\s|$)/$1$ENV{MODEL}$2/g;
                        $job_post_exec =~ s/PROGRAM_DIR/$ProgramDir/;
                        $job_post_exec =~ s/DUT/$dut/g;
                        $job_post_exec =~ s/NAME/$dut/g;
                    }
                }
                else {
                    undef $job_post_exec;
                }

                # Check to see if Job Contains Environment Settings
                undef @job_env
                  ; # Undef this variable so it doesn't get appended with everything previous.
                if ( defined $general_cmd->{JOB_ENV_SET} ) {
                    foreach my $env_set ( keys %{ $general_cmd->{JOB_ENV_SET} } ) {
                        $env_vars = $env_set;
                        $env_val  = $general_cmd->{JOB_ENV_SET}{$env_set};
                        $env_vars =~ s/NAME/$dut/g;
                        $env_val  =~ s/NAME/$dut/g;
                        $env_val  =~ s/GK_TASK_PREFIX/$ENV{'GK_TASK_PREFIX'}/g;
                        push @job_env, "set:$env_vars:$env_val";
                    }
                }

# Check to see if Job Contains Environment Arguments
# This code is experimental, only doing this because I cannot do a source from NBtask Environment block.
                undef $env_args;
                undef @env_cmd_string;
                undef $env_file;
                undef $env_source_cmd;
                undef @env_source_results;
                undef @env_cmds;
                if (   ( defined $general_cmd->{ENV_ARGS} )
                    && ( !defined $general_cmd->{LIST} )
                    && ( ~$print_commands ) )
                {
                    $VTMBTool->info(" Generating ENV Arguments for $job_name");
                    $VTMBTool->create_directories("$ENV{'MODEL'}/GATEKEEPER/env");
                    $env_args = $general_cmd->{ENV_ARGS};
                    $env_args =~ s/<MODEL>/$ENV{'MODEL'}/g;
                    $env_args =~ s/<DUT>/$dut/g;
                    @env_cmd_string = split( /;/, $env_args );
                    $env_file = "$ENV{'MODEL'}/GATEKEEPER/env/$job_name.env";
                    open( ENV_FILE, ">$env_file" ) || die "Cannot open file $env_file\n";
                    print ENV_FILE "#!/usr/intel/bin/tcsh -f\n";

                    foreach my $env_cmd (@env_cmd_string) {
                        print ENV_FILE "$env_cmd\n";
                        push @env_cmds, $env_cmd;
                    }
                    print ENV_FILE "printenv > $env_file.out\n";
                    close(ENV_FILE);
                }

                ## Check to see if SPAWN Task is set.
                my ( @spawn_task_desc, $spawn_desc, @job_spawn_task );
                if ( defined $general_cmd->{SPAWN_TASK} ) {
                    my $spawn_task_index = 0;
                    foreach my $spawn_task_idx ( @{ $general_cmd->{SPAWN_TASK} } ) {
                        $spawn_task = $spawn_task_idx;
                        $spawn_task =~ s/GK_DUT/$dut/;
                        $spawn_task =~ s/<GK_TASK_PREFIX>/$ENV{'GK_TASK_PREFIX'}/;
                        $spawn_task =~ s/GK_TASK_PREFIX/$ENV{'GK_TASK_PREFIX'}/;
                        $spawn_task =~ s/GK_TASK_AREA/$ENV{'GK_TASK_AREA'}/g;
                        $spawn_task =~ s/GK_NBPOOL/$job_nbpool/g;
                        $spawn_task =~ s/GK_NBCLASS/$job_nbclass/g;
                        $spawn_task =~ s/GK_NBQSLOT/$job_nbqslot/g;
                        $spawn_task =~ s/GK_CLUSTER/$ENV{'GK_CLUSTER'}/g;
                        $spawn_task =~ s/NAME/$dut/g;

                        # New Wildcard Format
                        $spawn_task =~ s/<DUT>/$dut/;

                        if ( defined $general_cmd->{SPAWN_TASK_DIR} ) {
                            my $spawn_task_dir = $general_cmd->{SPAWN_TASK_DIR};
                            $spawn_task_dir =~ s/(\s|^)MODEL(\/|\s|$)/$1$ENV{MODEL}$2/g;
                            push @job_spawn_task, "$spawn_task_dir/$spawn_task";
                        }
                        else {
                            push @job_spawn_task,
                              "$ENV{'GK_TASK_AREA'}/$ENV{'GK_TASK_PREFIX'}.$spawn_task";
                        }
                        $spawn_desc = $general_cmd->{SPAWN_DESC}->[$spawn_task_index];
                        $spawn_desc =~ s/NAME/$dut/g;
                        $spawn_desc =~ s/GK_TASK_PREFIX/$ENV{'GK_TASK_PREFIX'}/g;
                        $spawn_desc =~ s/GK_CLUSTER/$ENV{'GK_CLUSTER'}/g;

                        # New Wildcard Format
                        $spawn_desc =~ s/<DUT>/$dut/;

                        push @spawn_task_desc, $spawn_desc;
                        $spawn_task_index++;
                    }
                }
                else {
                    undef @job_spawn_task;
                }

# Set a dependency for use by simregress task dependency name.
# As of June 30, 2009, this hash is obsolete, it can be removed once GenerateRegression subroutine is deleted.
                $all_job_names{$job_name} = $job_name;

                # Add Task Name to Hash which maps job names to Tasks
                $job_2_task_names{$job_name} = "$VTMBObj->{TASK_PREFIX}.$job_name";

# To support Clone in Clone Update, WORKAREA can be overridden with GkUtils, this will affect $MODELROOT
                if ( !defined $general_cmd->{WORKAREA_EXTD} ) {
                    $task_ward = $VTMBObj->get('MODEL') . "/GATEKEEPER/NBFeederTaskJobs";
                    $task_modelroot = $VTMBObj->get('MODEL');
                }
                else {
                    $task_ward =
                        $VTMBObj->get('MODEL') . "/"
                      . $general_cmd->{WORKAREA_EXTD}
                      . "/GATEKEEPER/NBFeederTaskJobs";
                    $task_modelroot =
                      $VTMBObj->get('MODEL') . "/" . $general_cmd->{WORKAREA_EXTD};
                }

                # Add NBfeeder Machine Delegate Groups if needed.
                if (   ( defined $general_cmd->{DELEGATE_GROUP} )
                    && ( $GkEventType eq "MOCK" ) )
                {

                    # Determine if specified Machine Delegate Group is as follows.
                    # If 1, Delegate group equals $HOST.
                    # If List Delegate group equals the list of machines specified.

                    if ( ref $general_cmd->{DELEGATE_GROUP} eq 'ARRAY' ) {
                        $VTMBTool->error(
"Support for DELEGATE_GROUP as Array is not support, please set to Scalar containing a list of machine, or 1 to use the current HOST."
                        );

#$machine_delegate_group = join(" ",@{$general_cmd->{DELEGATE_GROUP}});
#$VTMBTool->info(" Job $general_cmd->{NAME} configured to run on Machine Delegate Group Array Override Specified: $machine_delegate_group ");
                    }
                    elsif ( ref $general_cmd->{DELEGATE_GROUP} eq 'HASH' ) {
                        $VTMBTool->error(
"Support for DELEGATE_GROUP as HASH is not support, please set to ARRAY containing a list of machine, or 1 to use the current HOST."
                        );
                    }
                    else {
                        if ( $general_cmd->{DELEGATE_GROUP} eq 1 ) {
                            $machine_delegate_group = $ENV{'HOST'};
                            $VTMBTool->info(
" Job $general_cmd->{NAME} configured to run on Machine Delegate Group Scalar Override on Host: $ENV{'HOST'} "
                            );
                        }
                        else {
                            $machine_delegate_group = $general_cmd->{DELEGATE_GROUP};
                            $VTMBTool->info(
" Job $general_cmd->{NAME} configured to run on Delegate Group Specified as List: $machine_delegate_group"
                            );
                        }
                    }
                }
                else {
                    undef $machine_delegate_group;
                }

            # For APD projects empty testlist are supported as placeholder within GK.
            #  To gk-utils this is seen as a silent error and not allowed.
            #  For RDH Enabling support has been added to opt into empty testlist support.
                if ( defined $general_cmd->{ALLOW_EMPTY_JOBFILE} ) {
                    $allow_empty_jobfile = 1;
                }
                else {
                    undef $allow_empty_jobfile;
                }

       # Determine if there is a pre-exec-script defined globally or locally within a job.
                if ( defined $general_cmd->{PRE_EXEC_JOB} ) {

                    # Create Pre Exec directory
                    $VTMBTool->create_directories("$ENV{'MODEL'}/GATEKEEPER/pre-exec");

                    # Process PRE_EXEC flag
                    $job_pre_exec =
                      &process_cfg_var( \$general_cmd, "JOB_PRE_EXEC", $GkEventType );
                    $job_pre_exec = $general_cmd->{PRE_EXEC_JOB};
                    if ( defined $job_pre_exec ) {
                        $job_pre_exec =~ s/(\s|^)MODEL(\/|\s|$)/$1$ENV{MODEL}$2/g;
                        $job_pre_exec =~ s/PROGRAM_DIR/$ProgramDir/;
                        $job_pre_exec =~ s/DUT/$dut/g;
                        $job_pre_exec =~ s/NAME/$dut/g;
                    }
                }
                elsif ( defined $Models{job_pre_exec} ) {

                    # Create Pre Exec directory
                    $VTMBTool->create_directories("$ENV{'MODEL'}/GATEKEEPER/pre-exec");

                    # Set job_pre_exec_key
                    $job_pre_exec = $Models{job_pre_exec};
                }
                else {
                    undef $job_pre_exec;
                }

                # Based on whether a List exists or not
                my ( $VTMBJobList, @temp_list );
                $general_cmd_mail_list = $general_cmd->{SEND_MAIL} if (defined $general_cmd->{SEND_MAIL});
                if ( !defined $general_cmd->{LIST} ) {
                    $VTMBTool->info("Adding Build String for $job_name");

                    # Create JOB Object
                    $VTMBJob = new VTMBJob(
                        DUT             => $dut,
                        NAME            => $job_name,
                        CMDS            => $job_cmd,
                        SEND_MAIL       => $general_cmd_mail_list,
                        CMD_TYPE        => $general_cmd->{CMD_TYPE},
                        ENV_FILE        => $env_file,
                        ENV_ARGS        => [@env_cmds],
                        DESC            => $job_desc,
                        DEPENDENCY      => [@job_dep],
                        DEPENDENCY_FULL => [@job_dep_full],
                        DEP_COND        => [@job_dep_cond],
                        WORKAREA        => $task_ward,
                        MODEL           => $task_modelroot,
                        CHECK           => $job_check,
                        GATING          => $job_gating,
                        EARLY_KILL      => $job_early_kill,
                        NBCLASS         => $job_nbclass,
                        NBPOOL          => $job_nbpool,
                        NBQSLOT         => $job_nbqslot,
                        JOB_POST_EXEC   => $job_post_exec,
                        JOB_PRE_EXEC    => $job_pre_exec,
                        JOB_TYPE        => $job_type,
                        ,
                        SPAWN_TASK          => [@job_spawn_task],
                        SPAWN_DESC          => [@spawn_task_desc],
                        JOB_ENV             => [@job_env],
                        NBJOB_OPTS          => $nbjob_opts,
                        DELEGATE_GROUP      => $machine_delegate_group,
                        AUTO_REQ            => $task_auto_req,
                        ALLOW_EMPTY_JOBFILE => $allow_empty_jobfile,
                        DISABLE_NB_CHECK    => $disable_nb_check,
                        SMART               => $smart,
                      )
                      or die
                      "Error Initializing VTMBJob Object. Report this bug to GK Owner\n";

                 # Check Job NB Settings to ensure this is a valid Netbatch Configuration.
                 # If this is a print commands invocation, turn error into warning.
                    if ( !defined $netbatch_settings{$job_nbpool}{$job_nbclass}
                        {$job_nbqslot} )
                    {
                        $VTMBJob->check_netbatch_settings( $VTMBTool, $print_commands,
                            \%netbatch_settings );

     # Commented out NBFlow team recommendation because it doesn't work on virtual pools.
     #$VTMBJob->validate_netbatch_settings($VTMBTool,$print_commands,\%netbatch_settings);
     # Add the job to the HASH for record keeping purposes.
                        push
                          @{ $netbatch_settings{$job_nbpool}{$job_nbclass}{$job_nbqslot}
                              {JOBS} }, $VTMBJob->{NAME};
                    }
                    else {

                        # Add the job to the HASH for record keeping purposes.
                        push
                          @{ $netbatch_settings{$job_nbpool}{$job_nbclass}{$job_nbqslot}
                              {JOBS} }, $VTMBJob->{NAME};
                    }

                    if ( !$print_commands ) {
                        if ( !$disable_create_taskfile ) {

                            # Task File Generation will be dependent on CMD_TYPE
                            if ( defined $VTMBJob->{CMD_TYPE}
                                && $VTMBJob->{CMD_TYPE} eq "acereg" )
                            {
                                $VTMBJob->create_cshfile($VTMBObj);
                                $VTMBJob->create_acereg_taskfile( $VTMBObj, $VTMBTool );
                            }
                            else {
                                if ( defined $VTMBJob->{ENV_FILE} ) {
                                    $VTMBJob->create_cshfile($VTMBObj);
                                    if ( defined $general_cmd->{TIMEOUT} ) {
                                        $VTMBJob->create_taskfile( $VTMBObj,
                                            $general_cmd->{TIMEOUT} );
                                    }
                                    else {
                                        $VTMBJob->create_taskfile( $VTMBObj,
                                            $Models{timeout}{build} );
                                    }
                                }
                                else {
                                    if ( defined $general_cmd->{TIMEOUT} ) {
                                        $VTMBJob->create_taskfile( $VTMBObj,
                                            $general_cmd->{TIMEOUT} );
                                    }
                                    else {
                                        $VTMBJob->create_taskfile( $VTMBObj,
                                            $Models{timeout}{build} );
                                    }
                                }
                            }
                        }
                    }

                    # Add Jobs to JobsArray & JobsMapArray
                    push @temp, $VTMBJob;
                    my $jobs_map = $ENV{'GK_TASK_PREFIX'} . "." . $VTMBJob->{NAME};
                    $VTMBJobsMap{$jobs_map} = $VTMBJob;
                }
                else {
                    foreach my $jlist (@jobs_list) {
                        chomp($jlist);
                        my ( $job_cmd_list, $job_name_list, $job_desc_list ) =
                          ( $job_cmd, $job_name, $job_desc );
                        $job_cmd_list  =~ s/<LIST>/$jlist/g;
                        $job_name_list =~ s/<LIST>/$jlist/g;
                        $job_desc_list =~ s/<LIST>/$jlist/g;

                        # Handle Dependency expansion on LIST
                        my ( @job_dep_list, @job_dep_full_list, $tmp_list );
                        if (@job_dep_full) {
                            foreach my $dep_list (@job_dep_full) {
                                $tmp_list = $dep_list;
                                $tmp_list =~ s/<LIST>/$jlist/g;
                                push @job_dep_full_list, $tmp_list;
                            }
                            foreach my $dep_list (@job_dep) {
                                $tmp_list = $dep_list;
                                $tmp_list =~ s/<LIST>/$jlist/g;
                                push @job_dep_list, $tmp_list;
                            }
                        }

# Check to see if Job Contains Environment Arguments
# This code is experimental, only doing this because I cannot do a source from NBtask Environment block.
                        undef $env_args;
                        undef @env_cmd_string;
                        undef $env_file;
                        undef $env_source_cmd;
                        undef @env_source_results;
                        undef @env_cmds;

                        # ENV_ARGS_LIST
                        if (   ( defined $general_cmd->{ENV_ARGS} )
                            && ( ~$print_commands ) )
                        {
                            $VTMBTool->info(" Generating ENV Arguments for $job_name");
                            $VTMBTool->create_directories("$ENV{'MODEL'}/GATEKEEPER/env");
                            $env_args = $general_cmd->{ENV_ARGS};
                            $env_args =~ s/<MODEL>/$ENV{'MODEL'}/g;
                            $env_args =~ s/<DUT>/$dut/g;
                            $env_args =~ s/<LIST>/$jlist/g;
                            @env_cmd_string = split( /;/, $env_args );
                            $env_file = "$ENV{'MODEL'}/GATEKEEPER/env/$job_name_list.env";
                            open( ENV_FILE, ">$env_file" )
                              || die "Cannot open file $env_file\n";
                            print ENV_FILE "#!/usr/intel/bin/tcsh -f\n";

                            foreach my $env_cmd (@env_cmd_string) {
                                print ENV_FILE "$env_cmd\n";
                                push @env_cmds, $env_cmd;
                            }
                            print ENV_FILE "printenv > $env_file.out\n";
                            close(ENV_FILE);
                        }

                        $VTMBTool->info("Expanding LIST for $job_name_list");
                        $VTMBJob = new VTMBJob(
                            DUT             => $dut,
                            NAME            => $job_name_list,
                            CMDS            => $job_cmd_list,
                            DESC            => $job_desc_list,
                            DEPENDENCY      => [@job_dep_list],
                            DEPENDENCY_FULL => [@job_dep_full_list],
                            DEP_COND        => [@job_dep_cond],
                            ENV_FILE        => $env_file,
                            ENV_ARGS        => [@env_cmds],
                            WORKAREA        => $task_ward,
                            MODEL           => $task_modelroot,
                            CHECK           => $job_check,
                            GATING          => $job_gating,
                            EARLY_KILL      => $job_early_kill,
                            NBCLASS         => $job_nbclass,
                            NBPOOL          => $job_nbpool,
                            NBQSLOT         => $job_nbqslot,
                            JOB_PRE_EXEC    => $job_pre_exec,
                            JOB_POST_EXEC   => $job_post_exec,
                            JOB_TYPE        => $job_type,
                            ,
                            SPAWN_TASK          => [@job_spawn_task],
                            SPAWN_DESC          => [@spawn_task_desc],
                            JOB_ENV             => [@job_env],
                            NBJOB_OPTS          => $nbjob_opts,
                            DELEGATE_GROUP      => $machine_delegate_group,
                            ALLOW_EMPTY_JOBFILE => $allow_empty_jobfile,
                            DISABLE_NB_CHECK    => $disable_nb_check,
                          )
                          or die
"Error Initializing VTMBJob Object. Report this bug to GK Owner\n";

                 #
                 # Check Job NB Settings to ensure this is a valid Netbatch Configuration.
                 # If this is a print commands invocation, turn error into warning.
                        if ( !defined $netbatch_settings{$job_nbpool}{$job_nbclass}
                            {$job_nbqslot} )
                        {
                            $VTMBJob->check_netbatch_settings( $VTMBTool, $print_commands,
                                \%netbatch_settings );

     # Commented out NBFlow team recommendation because it doesn't work on virtual pools.
     #$VTMBJob->validate_netbatch_settings($VTMBTool,$print_commands,\%netbatch_settings);
     # Add the job to the HASH for record keeping purposes.
                            push @{ $netbatch_settings{$job_nbpool}{$job_nbclass}
                                  {$job_nbqslot}{JOBS} }, $VTMBJob->{NAME};
                        }
                        else {

                            # Add the job to the HASH for record keeping purposes.
                            push @{ $netbatch_settings{$job_nbpool}{$job_nbclass}
                                  {$job_nbqslot}{JOBS} }, $VTMBJob->{NAME};
                        }

                        if ( !$print_commands ) {
                            if ( !$disable_create_taskfile ) {

                                # Task File Generation will be dependent on CMD_TYPE
                                if ( defined $VTMBJob->{CMD_TYPE}
                                    && $VTMBJob->{CMD_TYPE} eq "acereg" )
                                {
                                    $VTMBJob->create_cshfile($VTMBObj);
                                    $VTMBJob->create_acereg_taskfile( $VTMBObj,
                                        $VTMBTool );
                                }
                                else {
                                    if ( defined $VTMBJob->{ENV_FILE} ) {
                                        $VTMBJob->create_cshfile($VTMBObj);
                                        if ( defined $general_cmd->{TIMEOUT} ) {
                                            $VTMBJob->create_taskfile( $VTMBObj,
                                                $general_cmd->{TIMEOUT} );
                                        }
                                        else {
                                            $VTMBJob->create_taskfile( $VTMBObj,
                                                $Models{timeout}{build} );
                                        }
                                    }
                                    else {
                                        if ( defined $general_cmd->{TIMEOUT} ) {
                                            $VTMBJob->create_taskfile( $VTMBObj,
                                                $general_cmd->{TIMEOUT} );
                                        }
                                        else {
                                            $VTMBJob->create_taskfile( $VTMBObj,
                                                $Models{timeout}{build} );
                                        }
                                    }
                                }
                            }
                        }

                        # Add Jobs to JobsArray & JobsMapArray
                        push @temp, $VTMBJob;
                        my $jobs_map = $ENV{'GK_TASK_PREFIX'} . "." . $VTMBJob->{NAME};
                        $VTMBJobsMap{$jobs_map} = $VTMBJob;

                    }

                }
            }
        }
    }

    # Terminate on errors
    $VTMBTool->check_errors();

    #Return Jobs
    return @temp;
}

#-------------------------------------------------------------------------------
# CreateRegressions()
#   Based on the Duts being built. Generate the Regression Jobs
#-------------------------------------------------------------------------------
sub CreateRegressions {
    my $disable_create_taskfile = shift(@_);

    # Display status and set up indentation
    $VTMBTool->indent_msg(0);
    $VTMBTool->info("Setting up Regression Jobs for All Duts");
    $VTMBTool->indent_msg(2);

    my ( $jobs, $test_list, $test_args, $i, $j );
    my ( @temp, @cluster_2_regress, );
    my ( $dut,  $build_task_name );
    my ( $rpt_file, $job_file, $task_file );
    my (@regression_jobs);
    my ($test_count);
    my ($pass_rate) =
      100;   # Assumed Regressions must pass by 100%, unless Specific List Override Exists
    my $task_name;
    my (%regression_added);
    my $smart = 0;

# If we are process a turnin, release, mock turnin, or filter build.
# The expectation is there will always be a build job.
# We rely on this fact when searching the regression list hash.
# POST-RELEASE is for just because I don't need to write extra code before sabbatical, I will fix when I return.
    if (   ( $GkEventType eq "RELEASE" )
        || ( $GkEventType eq "TURNIN" )
        || ( $GkEventType eq "FILTER" )
        || ( $GkEventType eq "MOCK" )
        || ( $GkEventType eq "POST-RELEASE" ) )
    {
        my %current_test_lists = ();
        my %mock_test_lists    = ();

        if ( $ENV{'GK_SMART_MODE'} ) {
            my %jobs_2_build = map { $_->{NAME} => 1 } @VTMBJobs;
          TESTLIST: foreach my $test_list ( @{ $Models{reglist} } ) {
                if (defined $test_list->{CONDITIONAL}) {
                    $VTMBTool->info("Inside conditional recipe processing section");
                    if (&isMatching(\@fileschanged, $test_list->{CONDITIONAL}) == 1) {
                        $VTMBTool->info("Skipping recipe event $test_list->{NAME} as incoming change doesnt match any given regular expressions");
                        next;
                    }
                }
                #Smart Waiver: Skip dut regressions when it is skipped by SmartBuild
                if ( defined @smart_waivers ){
                    my %sw_duts = map {$_ => 1} keys %smart_waiver_tree;
                    my $reg_dut = $test_list->{DUT};
                    if( $sw_duts{$reg_dut} ){
                        my $no_reg = 0;
                        foreach my $cxt ( keys $RunStages{$reg_dut} ){
                            if ($RunStages{$reg_dut}{$cxt} eq 0) {
                                $no_reg = 1;
                            }
                        }
                        next TESTLIST if ($no_reg);
                    }
                }
                if ( defined $test_list->{DEPENDENCY}
                    && !exists $current_test_lists{ $test_list->{NAME} } )
                {
                    my $skip_testlist = 0;
                    foreach ( keys %{ $test_list->{DEPENDENCY} } ) {
                        my $dep_name = $_;
                        $dep_name =~ s|^/([^/]+)/.+$|${1}|;

                        # Search the dep job in current VTMBJobs list
                        if (   not exists $jobs_2_build{"$dep_name"}
                            or not $jobs_2_build{"$dep_name"} )
                        {
                            $skip_testlist = 1;
                            $VTMBTool->info(
"SmartGk:Skipping $test_list->{NAME} since $dep_name is not going to run"
                            );
                        }
                    }
                    next TESTLIST if ($skip_testlist);
                }

          # Determine if this regression is configured for this GkEventType and GK_CLUSTER
                my %cluster_2_regress = map { $_ => 1 } (
                    exists $test_list->{$GkEventType}
                    ? split( ' ', $test_list->{$GkEventType} )
                    : ()
                );

#         @cluster_2_regress = exists $test_list->{$GkEventType} ? split(/ /,$test_list->{$GkEventType}) : ();
                if ( $cluster_2_regress{"$ENV{'GK_CLUSTER'}"}
                    && !exists $current_test_lists{ $test_list->{NAME} } )
                {
                    $VTMBTool->info("SmartGk:Adding Regression job $test_list->{NAME}");

                    #Invoke Simregress to create the regression area then exit loop.
                    $VTMBJob = &InvokeSimRegress( $jobs, $test_list );
                    $current_test_lists{ $test_list->{NAME} } = 1;
                    push @regression_jobs, $VTMBJob;
                }
            }
        }
        else {
            foreach $jobs (@VTMBJobs) {
                $VTMBTool->info("Searching for Regressions for $jobs->{NAME}");
                $dut = $jobs->{DUT};

      # Search thru the jobs till one of them matches a dependency in the regression list.
                my $test_added;
                foreach $test_list ( @{ $Models{reglist} } ) {
                    $test_added = 0;

                    if ( defined $test_list->{SMART} ) {
                        $smart = $test_list->{SMART};
                    }

                    # Look for DUT and Dependency match
                    if ( defined $test_list->{DEPENDENCY}
                        && !
                        exists $current_test_lists{ $test_list->{NAME} }
                      )    # && ($jobs->{NAME} eq (keys %{$test_list->{DEPENDENCY}}->[0]))
                    {
                        my $cont = 0;
                        foreach ( keys %{ $test_list->{DEPENDENCY} } ) {
                            $cont = 1 if $jobs->{NAME} eq $_;
                        }
                        next unless $cont;

          # Determine if this regression is configured for this GkEventType and GK_CLUSTER
                        @cluster_2_regress =
                          exists $test_list->{$GkEventType}
                          ? split( / /, $test_list->{$GkEventType} )
                          : ();

# Append to the list of Cluster if this is a GK MOCK Level 1 event.
# This allows a testlist which might not be configurated for this cluster in the Current GKEventType to be used.
                        push( @cluster_2_regress,
                            $Models{Cluster2Dut}{ $ENV{'GK_CLUSTER'} } )
                          if AddGkLevel1TestList($test_list);

                        for ( $i = 0 ; $i < @cluster_2_regress ; $i += 1 ) {
                            if ( $test_list->{NAME} =~ /fast/ ) {
                                my $a;
                            }

# This is a Hack, ideally there is only 1 instance of a L0 or L1 per dut. For Core release model, we support Sles9 & Sles10 regressions.
                            if ( $GkEventType ne "MOCK" ) {
                                if ( $cluster_2_regress[$i] eq $ENV{'GK_CLUSTER'}
                                    && !exists $current_test_lists{ $test_list->{NAME} } )
                                {

                                    $VTMBTool->info(
"   Found Regressions for $jobs->{NAME}: $test_list->{NAME}"
                                    );

                          #Invoke Simregress to create the regression area then exit loop.
                                    $VTMBJob =
                                      &InvokeSimRegress( $jobs, $test_list,
                                        $disable_create_taskfile );
                                    $current_test_lists{ $test_list->{NAME} } = 1;
                                    push @regression_jobs, $VTMBJob;
                                    $test_added = 1;
                                    last;
                                }
                            }
                            else {

# For Mock Turnin, there is a GK Mock Level 1 support in which a dut is added but the testlist is probably not configured for this cluster.
# As a result, cluster_2_regress has been appended with these dut names, in this case they need to be treated as clusters.
                                if (
                                    (
                                        (
                                            defined $ENV{'GK_LEVEL1'}
                                            && ( $cluster_2_regress[$i] eq
                                                $ENV{'GK_CLUSTER'} )
                                        )
                                        || (
                                            $cluster_2_regress[$i] eq $ENV{'GK_CLUSTER'} )
                                    )
                                    && !exists $mock_test_lists{ $test_list->{NAME} }
                                  )
                                {

                                    $VTMBTool->info(
"   Found Regressions for $jobs->{NAME}: $test_list->{NAME}"
                                    );

                          #Invoke Simregress to create the regression area then exit loop.
                                    $VTMBJob =
                                      &InvokeSimRegress( $jobs, $test_list,
                                        $disable_create_taskfile );
                                    $mock_test_lists{ $test_list->{NAME} } = 1;
                                    push @regression_jobs, $VTMBJob;
                                    $test_added = 1;
                                    last;
                                }
                            }
                        }

                        # Check for ADD Tasks
                        my ( $add_cmd, $add_name, $add_gating, $add_dut );
                        my ( @add_dependency, @add_dependency_cond,
                            @add_dependency_full );

                        if (
                            $test_added
                            && (   ( defined $test_list->{ADD_CMD} )
                                && ( defined $test_list->{ADD_EVENT}->{$GkEventType} ) )
                          )

#if(((defined $test_list->{ADD_CMD}) && (defined $test_list->{ADD_EVENT}->{$GkEventType})))
                        {
                            $add_cmd    = $test_list->{ADD_CMD};
                            $add_name   = $test_list->{ADD_NAME};
                            $add_gating = $test_list->{ADD_GATING};
                            $add_dut    = $test_list->{DUT};
                            push @add_dependency,      $VTMBJob->{TASK_NAME};
                            push @add_dependency_cond, "Success";
                            push @add_dependency_full, "$test_list->{NAME} : Success";

                            # Handle CAMA Enabling.
                            if ( defined $ENV{'RTL_PROJ_BIN'} ) {
                                $add_cmd =~ s/RTL_PROJ_BIN/$ENV{'RTL_PROJ_BIN'}/;
                            }
                            if ( defined $ENV{'CAMA_MODEL_CACHING_DISK'} ) {
                                $add_cmd =~
s/CAMA_MODEL_CACHING_DISK/$ENV{'CAMA_MODEL_CACHING_DISK'}/;
                                $add_cmd =~ s/CACHE_DUT/$dut/;
                                if (   ( defined $test_list->{BIT_MODE} )
                                    && ( $test_list->{BIT_MODE} == 64 ) )
                                {
                                    $add_cmd =~ s/BIT_MODE/$test_list->{BIT_MODE}/;
                                }
                                else {
                                    $add_cmd =~ s/BIT_MODE/32/;
                                }
                            }

                            my $VTMBAdd = new VTMBJob(
                                CMDS            => $add_cmd,
                                DUT             => $add_dut,
                                NAME            => $add_name,
                                DESC            => $add_name,
                                GATING          => $add_gating,
                                DEPENDENCY_FULL => [@add_dependency_full],
                                DEPENDENCY      => [@add_dependency],
                                DEP_COND        => [@add_dependency_cond],
                                GENERAL_JOB     => 1,
                                NBPOOL          => $VTMBJob->{NBPOOL},
                                NBCLASS         => $VTMBJob->{NBCLASS},
                                NBQSLOT         => $VTMBJob->{NBQSLOT},
                                GENERAL_JOB     => 1,
                                WORKAREA        => $VTMBObj->get('MODEL')
                                  . "/GATEKEEPER/NBFeederTaskJobs",
                                MODEL            => $VTMBObj->get('MODEL'),
                                DISABLE_NB_CHECK => $disable_nb_check,
                                SMART            => $smart,
                              )
                              or die
"Error Initializing VTMBJob Object. Report this bug to GK Owner\n";

                            # Create Task file for ADD Task
                            if ( !$print_commands ) {
                                if ( defined $test_list->{TIMEOUT} ) {
                                    $VTMBAdd->create_taskfile( $VTMBObj,
                                        $test_list->{TIMEOUT} );
                                }
                                else {
                                    $VTMBAdd->create_taskfile( $VTMBObj,
                                        $Models{timeout}{build} );
                                }
                                if ( defined $job_2_task_names{$add_name} ) {
                                    my (
                                        $message, $report_txt, $email_list,
                                        $subject, $cc_list
                                    ) = ( "", "", "", "", "" );
                                    $email_list = $ENV{'GK_USER'} || $ENV{'USER'};
                                    $email_list =~ s/\s+/,/g;
                                    $message =
"There is a Duplicated Job Name which could adversely affect dependencies.\n";
                                    $message .=
"The job name is $job_2_task_names{$add_name} located in $ENV{'MODEL'}\n";
                                    $message .= "Please contact GK Admin\n\n";
                                    $subject =
"There is a Duplicated Job Name in $ENV{'GK_CLUSTER'}  $ENV{'GK_STEP'} $ENV{'GK_EVENTTYPE'} recipe";
                                    $VTMBAdd->job_status_email(
                                        $email_list, $ENV{'USER'}, $cc_list,
                                        $subject,    $message
                                    );
                                    $VTMBTool->error(
"Please Contact GK Admin, condition of duplicated job name should not occur: $add_name "
                                    );
                                }
                                $job_2_task_names{$add_name} = $VTMBAdd->{TASK_NAME};
                            }

                            # Add to list of Regression Jobs
                            push @regression_jobs, $VTMBAdd;
                        }

                    }
                }
            }
        }
    }
    if ( @regression_jobs && exists $Models{deleteNBFeederLogs} ) {
        my @job_dependency      = ();
        my @job_dependency_cond = ();
        my @job_dependency_full = ();

        foreach my $job (@regression_jobs) {
            push( @job_dependency,      $job->{TASK_NAME} );
            push( @job_dependency_cond, "Finish" );
            push( @job_dependency_full, "$job->{TASK_NAME} : Finish" );

        }

        #Add JobFile to a Jobs Structure
        $VTMBJob = new VTMBJob(
            CMDS             => "$Models{deleteNBFeederLogs}",
            NAME             => "remove_nbfeeder_logs.$ENV{'GK_EVENTTYPE'}",
            JOBFILE          => $job_file,
            DESC             => "Remove nbfeeder logs",
            DEPENDENCY       => [@job_dependency],
            DEPENDENCY_FULL  => [@job_dependency_full],
            DEP_COND         => [@job_dependency_cond],
            TASK_NAME        => "$ENV{'GK_TASK_PREFIX'}.remove_nbfeeder_logs",
            TASK_FILE        => "remove_nbfeeder_logs.$ENV{'GK_EVENTTYPE'}",
            GATING           => 0,
            GENERAL_JOB      => 1,
            NBPOOL           => "$ENV{NBPOOL}",
            NBCLASS          => "$ENV{NBCLASS}",
            NBQSLOT          => "$ENV{NBQSLOT}",
            WORKAREA         => $VTMBJob->{WORKAREA},
            MODEL            => $VTMBJob->{MODEL},
            DISABLE_NB_CHECK => $disable_nb_check,
            SMART            => $smart,
        ) or die "Error Initializing VTMBJob Object. Report this bug to GK Owner\n";
        if ( !$print_commands ) {
            if ( defined $test_list->{TIMEOUT} ) {
                $VTMBJob->create_taskfile( $VTMBObj, $test_list->{TIMEOUT} );
            }
            else {
                $VTMBJob->create_taskfile( $VTMBObj, $Models{timeout}{build} );
            }
        }
        push @regression_jobs, $VTMBJob;
    }

    # Terminate on errors
    $VTMBTool->check_errors();

    # Loop Thru Regression and add them to VTMBJobsMap.
    foreach my $hash_ref (@regression_jobs) {
        my $jobs_map = $ENV{'GK_TASK_PREFIX'} . "." . $hash_ref->{NAME};
        $VTMBJobsMap{$jobs_map} = $hash_ref;
    }

    # Add the Regression Jobs and return Array
    @regression_jobs = ( @VTMBJobs, @regression_jobs );
    return @regression_jobs;
}

#-------------------------------------------------------------------------------
# AddTestList()
#   Return1 if the testlist should be added according to GK_LEVEL1
#-------------------------------------------------------------------------------
sub AddTestList {
    return 0 unless ( exists $ENV{GK_LEVEL1} && $ENV{'GK_EVENTTYPE'} eq "mock" );
    my $name           = shift;
    my %gk_level1_duts = ();
    foreach ( split( /\s+/, $ENV{GK_LEVEL1} ) ) {
        return 1 if $name =~ /${_}_level.*regression/;
    }
    return 0;
}

#-------------------------------------------------------------------------------
# AddGkLevel1TestList()
#   Return1 if the testlist should be added according to GK_LEVEL1
#-------------------------------------------------------------------------------
sub AddGkLevel1TestList {
    return 0 unless ( exists $ENV{GK_LEVEL1} && $ENV{'GK_EVENTTYPE'} eq "mock" );
    my $test_list      = shift;
    my %gk_level1_duts = ();

    if ( defined $test_list->{$GkEventType} ) {
        foreach ( split( /\s+/, $ENV{GK_LEVEL1} ) ) {
            return 1 if $test_list->{NAME} =~ /${_}_level.*regression/;
        }
    }
    return 0;
}

#-------------------------------------------------------------------------------
# InvokeSimRegress()
#   Based on the Duts being built. Generate the Regression Jobs
#-------------------------------------------------------------------------------
sub InvokeSimRegress {
    my ( $jobs, $test_list, $disable_create_taskfile ) = @_;

    # Display status and set up indentation
    $VTMBTool->indent_msg(0);
    $VTMBTool->indent_msg(2);

    my ( $cmd, @cmd_results, @cmd_results2, $line, $ward );
    my ( @temp,      @cluster_2_regress, );
    my ( $task_name, $task_path );
    my ( $dut,       $build_task_name );
    my ( $rpt_file,  $job_file, $task_file );
    my ($test_count);
    my ($pass_rate) =
      100;   # Assumed Regressions must pass by 100%, unless Specific List Override Exists
    my ( $gating, $j );
    my ( $job_nbpool, $job_nbclass, $job_nbqslot, $job_type );
    my ( @test_dependency, @test_dependency_cond, @test_dependency_full );
    my ($regress_stats);
    my ( $job_early_kill, $nbjob_opts );
    my ( $task_ward,      $task_modelroot );
    my $smart = 0;
    my $regress_mail_list;
    $dut = $test_list->{'DUT'};
    $regress_mail_list = $test_list->{'SEND_MAIL'} if (defined $test_list->{SEND_MAIL});
    my $regress_output;
    my $regress_nb_output;
    $task_name       = $ENV{'GK_TASK_PREFIX'} . "." . $test_list->{NAME} . "." . "$dut";
    $task_path       = "/$VTMBObj->{TASK_PREFIX}/${task_name}";

    # This is the default commandline, we will append other flags as needed below
    my $runreg_cmd_no_rid = "";
    if ((defined $Models{force_random}) && ($ENV{GK_EVENTTYPE} eq "release")) {
       $runreg_cmd_no_rid = "runreg -dut $dut -l $test_list->{'LIST'} -gkt -taskname $task_name ";
    } else {
       $runreg_cmd_no_rid = "runreg -dut $dut -l $test_list->{'LIST'} -gkt -seed 1 -taskname $task_name ";
    }

    my $runreg_cmd = $runreg_cmd_no_rid . "-rid ${dut}_gk_regression ";

    # Checking the flag once
    my $disable_links = ((!defined $Models{disable_runreg_links_creation}) || ($Models{disable_runreg_links_creation} == 0));
    $ENV{LISTNAME} = "gk" if ($disable_links);

    #if ( $ENV{GK_EVENTTYPE} eq "mock" ) {
    #    if ( ( $ENV{DISABLE_NOCLEAN} )
    #            || ( $dut ne "arb_clt" )
    #            || ( $dut ne "msg_clt" )
    #            || ( $dut ne "l3bank_clt" )
    #            || ( $dut ne "ga_clt" )
    #            || ( $dut ne "gt" ) ) {
    #        $cmd = $runreg_cmd;
    #    } else {
    #        $cmd = $runreg_cmd . "-noclean ";
    #    }
    #}
    if ( $ENV{GK_EVENTTYPE} eq "release" ) {
        if ( $test_list->{ARGS} =~ /-rid\s*(\w*)\s*/ ) {
            my $rid_append = $1;
            $VTMBTool->info("Detected -rid switch in test_list of $dut. Appending $rid_append to -rid ${dut}_gk_regression");
            $cmd = $runreg_cmd_no_rid . "-rid ${dut}_gk_regression/$rid_append -enableSimmon ";
        } else {
            $cmd = $runreg_cmd . "-enableSimmon ";
        }
    } else {
        if ( $test_list->{ARGS} =~ /-rid\s*(\w*)\s*/ ) {
            my $rid_append = $1;
            $VTMBTool->info("Detected -rid switch in test_list of $dut. Appending $rid_append to -rid ${dut}_gk_regression");
            $cmd =  $runreg_cmd_no_rid . "-rid ${dut}_gk_regression/$rid_append -enableSimmon ";
        } else {
            $cmd = $runreg_cmd . "-enableSimmon ";
        }
    }

    if ($disable_links) {
        $cmd .= "-v $rid ";
    } else {
        $cmd .= "-m $regress_path -regress_dir $regress_path/regress ";
    }

    #SMADAN1 DYNAMIC LINK CREATION DUTs work_dir/models/GK (if available) to $link_path
    my ($tmp, $link_path);
    if (! defined $Models{disable_runreg_links_creation} || ($Models{disable_runreg_links_creation} == 0))
    {
	my $workdir = `grep work_dir "$ENV{PROJ}/validation/list/gk.list"`;
    	chomp($workdir);
    	( $tmp, $link_path ) = split /: /, $workdir;
    	$link_path =~ s/\$PROJ\//$ENV{PROJ}\//;
    	$link_path =~ s/[\s\t\n]+//g;
    	$link_path .= "/regress/";

    	my $dut_workdir = `grep work_dir "$ENV{PROJ}/validation/list/$dut.list"`;
    	chomp($dut_workdir);
    	my ( $tmp_dut, $link_path_dut ) = split /: /, $dut_workdir;
    	$link_path_dut =~ s/\$PROJ\//$ENV{PROJ}\//;
    	$link_path_dut =~ s/[\s\t\n]+//g;
    	$link_path_dut .= "/regress/GK";

	#Create folder $link_path/$dut_gk_regression if it doesn't exist. Create it with 777 permissions

    	if ( not -e "$link_path/${dut}_gk_regression" ) {
    	    `mkdir -p $link_path/${dut}_gk_regression -m 777`;
    	}

    	if ( -e "$link_path/${dut}_gk_regression/$rid" ) {

    	    $VTMBTool->info(
    	        "Deleting already existing directory $link_path/${dut}_gk_regression/$rid \n"
    	    );
    	    `rm -rf $link_path/${dut}_gk_regression/$rid`;

    	}
    }
    my $depstr = "";

    if ( defined $test_list->{SMART} ) {
        $smart = $test_list->{SMART};
    }

    if ( defined $test_list->{DEPENDENCY} ) {
        foreach my $build_dep ( keys %{ $test_list->{DEPENDENCY} } ) {
            my $dep_name = $build_dep;
            my $sub_dep  = "";

            #Adding dependency to regressions

            if ( $dep_name =~ m|^/([^/]+)(/.+)$| ) {
                $dep_name = $1;
                $sub_dep  = $2;

            }

            # This is contentious, will come back to later.
            if ( defined $job_2_task_names{$dep_name} ) {
                my $full_dep = "$job_2_task_names{$dep_name}${sub_dep}";
                $depstr .= "\n\tDependsOn ${full_dep}"
                  . "[On$test_list->{DEPENDENCY}{$build_dep}]\n";
                push @test_dependency,      $full_dep;
                push @test_dependency_cond, "$test_list->{DEPENDENCY}{$build_dep}";
                push @test_dependency_full,
                  "$test_list->{NAME} : $test_list->{DEPENDENCY}{$build_dep}";
            }
        }
    }

# Look for Arguments that may bneeed to be added to a testlist.
# There are two types, 1 is global, ARGS. The other is conditions, ARGS_COND for specific GK event types.
# Add Global arguments to Test List if defined
    if ( defined $Models{reglist_global_args} ) {
        $cmd .= " $Models{reglist_global_args} ";
    }

    #   Creating NEW link for all filter/turnin/release

    if (! defined $Models{disable_runreg_links_creation} || ($Models{disable_runreg_links_creation} == 0))
    {
	if ( $test_list->{ARGS} =~ /-rid\s*(\w*)\s*/ ) {

    	    my $rid_append = $1;
    	    if ( not -e "${regress_path}/regress/${rid}_${dut}_regression/$rid_append" ) {
    	        `mkdir -p ${regress_path}/regress/${rid}_${dut}_regression/$rid_append -m 777`;
    	    }
    	    $VTMBTool->info(
    	        "Creating NEW link with RID from ${regress_path}/regress/${rid}_${dut}_regression to ${link_path}/${dut}_gk_regression/$rid_append/${rid}\n"
    	    );
    	    $VTMBTool->run(
    	        "\\ln -fs '${regress_path}/regress/${rid}_${dut}_regression/$rid_append' '${link_path}/${dut}_gk_regression/$rid_append'"
    	    );
    	}
    	else {
    	    $VTMBTool->info(
    	        "Creating NEW link from ${regress_path}/regress/${rid}_${dut}_regression to ${link_path}/${dut}_gk_regression/${rid}\n"
    	    );
    	    $VTMBTool->run(
    	        "\\ln -fs '${regress_path}/regress/${rid}_${dut}_regression' '${link_path}/${dut}_gk_regression/${rid}'"
    	    );
    	}
   }
    if ( exists $test_list->{ARGS} ) {
        if ( $test_list->{ARGS} =~ /-rid\s*(\w*)\s*/ ) {
            my $rid_append = $1;
            $test_list->{ARGS} =~ s/-rid\s*$rid_append\s*//g;
        }
    }

    if ( exists $test_list->{ARGS} ) {
        $test_list->{ARGS} =~ s/TASK_TAG/$VTMBObj->{TASK_TAG}/g;
        $test_list->{ARGS} =~ s/post-release/release/g;

        # workaround to avoid -triage failures in mock turnins
        if ( $ENV{'GK_EVENTTYPE'} eq "mock" ) {
            $test_list->{ARGS} =~ s/\-triage.*\-triage\-//g;
            $test_list->{ARGS} =~ s/\-trex\s+\-trex\-//;
        }
        $cmd .= " $test_list->{ARGS} ";
    }

    if ( exists $test_list->{ARGS_COND}{ $ENV{'GK_EVENTTYPE'} } ) {
        $test_list->{ARGS_COND}{ $ENV{'GK_EVENTTYPE'} } =~
          s/TASK_TAG/$VTMBObj->{TASK_TAG}/g;
        $cmd .= " $test_list->{ARGS_COND}{$ENV{'GK_EVENTTYPE'}} ";
    }

    $cmd =~ s/RTL_PROJ_BIN/$ENV{RTL_PROJ_BIN}/g;
    $cmd =~ s/(\s|^)MODEL(\/|\s|$)/$1$ENV{MODEL}$2/g if $ENV{PROJECT} eq 'gmdhw';
    $cmd =~ s/PROGRAM_DIR/${ProgramDir}/g;

    # Handle Netbatch Variable Overrides
    ( $job_nbpool, $job_nbclass, $job_nbqslot ) = determine_nb_configuration(
        $test_list,             $test_list->{'NAME'},    $GkEventType,
        $ENV{'GK_MOCK_NBPOOL'}, $ENV{'GK_MOCK_NBCLASS'}, $ENV{'GK_MOCK_NBQSLOT'},
        $ENV{'NBPOOL'},         $ENV{'NBCLASS'},         $ENV{'NBQSLOT'}
    );

    # Add NB Variables to Commandline
    $cmd .= "-pool \"$job_nbpool\" -class \"$job_nbclass\" -queue \"$job_nbqslot\" ";

    #adding no_launch to the runreg command line at the end

    $cmd .= "-no_launch ";

    # This Code removes the implicit mode based on Job Name.

# If in Mock Turnin , enable users the ability to add additional arguements to simregress commandline.
    if (   ( $GkEventType eq "MOCK" )
        && ( defined $ENV{'GK_MOCK_SIMREGRESS_ADD'} ) )
    {
        $cmd .= " $ENV{'GK_MOCK_SIMREGRESS_ADD'}";
    }

    if ( !$print_commands ) {

#   $VTMBTool->info("Running elaboration on model $rid now");
# AT 10/09/13 write to regress dir instead
# $VTMBTool->create_directories($VTMBObj->get('MODEL') . "/log/${rid}_${dut}_regression");
    if (! defined $Models{disable_runreg_links_creation} || ($Models{disable_runreg_links_creation} == 0))
    {
        $VTMBTool->create_directories(
            $VTMBObj->get('MODEL') . "/regress/${rid}_${dut}_regression" );
        my $workdir = `grep work_dir "$ENV{PROJ}/validation/list/gk.list"`;
        chomp($workdir);
        my ( $tmp, $link_path ) = split /: /, $workdir;
        $link_path =~ s/\$PROJ\//$ENV{PROJ}\//;
        $link_path =~ s/[\s\t\n]+//g;
        $link_path .= "/regress";
    }
# AT 10/09/13 write to regress dir instead
#$VTMBTool->info("Creating NEW link from ${regress_path}/log/${rid}_${dut}_regression to ${link_path}/${dut}_gk_regression/${rid}\n");
#$VTMBTool->run("\\ln -fs '${regress_path}/log/${rid}_${dut}_regression' '${link_path}/${dut}_gk_regression/${rid}'");

    }

# Look for Additional Test Arguments which may need to be added to Simregress invocations.
# Commented out till needed.
#foreach $test_args (@{$Models{append_testlist}})
# {
#   if($test_args->{DUT} eq $test_list->{DUT})
#    {
#      $cmd .= " -trex $test_args->{ARGS} -trex- ";
#    }
# }

#    # Add Policy to dump regression status at regular interval
#    $regress_stats = basename( $test_list->{LIST} ) . ".STATUS";
#    $cmd .=
#"-task_mid '-freq 17m -name $ProgramDir/gk_regress_jobs.pl -status ../../$regress_stats' -task_mid- ";
#
# To support Clone in Clone Update, WORKAREA and MODELROOT can be overridden with GkUtils.
# For regressions chdir to MODEL so simregress collateral ends up in the correct location.
    if ( defined $test_list->{WORKAREA_EXTD} ) {
        $task_modelroot = $VTMBObj->get('MODEL') . "/" . $test_list->{WORKAREA_EXTD};
    }
    else {
        $task_modelroot = $VTMBObj->get('MODEL');
    }

    chdir $task_modelroot;

    my $svn_retry_count = 0;
    ### Skip if -commands
    if ( !$print_commands ) {
      SVNRETRY:
        $VTMBTool->info("Generating NBFeeder Job File for $test_list->{'NAME'}");
        if ( $VTMBTool->run( $cmd, \@cmd_results ) == 0 ) {

            # Looks like runreg will exit with "0" but testlib may error out
            # Print Results to log file
            my $runreg_dut = $test_list->{DUT};
            open( LOGFILE, ">>$regress_path/GATEKEEPER/runreg_output_$runreg_dut.log" );
            print LOGFILE @cmd_results;
            close LOGFILE;

   # Simregress invocation was successful. CD back to root MODEL if in different location.
            if ( $task_modelroot ne $ENV{'MODEL'} ) {
                chdir $ENV{'MODEL'};
            }

            #Grab Location of nbtask file created by runreg

            foreach $line (@cmd_results) {
                chomp $line;
                if ( $line =~ /Task file created\:\s*(.*)/ ) {
                    $task_file = $1;
                    $VTMBTool->debug("Task file found: $1");
                    chomp $task_file;
                    my $taskfile_name = basename($task_file);
                    my $link_file = &catfile($ENV{'GK_TASK_AREA'}, $taskfile_name);
                    $VTMBTool->info("Creating link for runreg taskfile: $link_file");
                    symlink($task_file, $link_file)

                }
            }
            open( TASKFILE, "<$task_file" )
              or die print
"gk-utils.pl was not able to grab the location of the runreg task file. Exiting...
Check whether you have proper SVN permissions to checkout Fulsim/val svn tests...
To get SVN permission please run the command \"svn_check\" and follow the on-screen instructions...
Try running the program again...
If you are still seeing this message after getting SVN permissions. Please raise this issue with your local DA\n";
            my @taskfile = <TASKFILE>;
            close(TASKFILE);

            #logic to add "DependsOn" in regression task file

            for my $x ( 0 .. $#taskfile ) {
                $line = $taskfile[$x];
                if ( $line =~ /Jobsfile\s(.*)/i ) {
                    $job_file = $1;
                    chomp $job_file;

                    tie my @array, 'Tie::File', $job_file or die $!;
                    foreach my $line (@array) {
                        if ( $line =~ /nbjob run/ ) {
                            if ( exists $test_list->{'TIMEOUT'} ) {
                                $line =~
s/nbjob run/nbjob run --job-constraints \"wtime>$test_list->{'TIMEOUT'}:kill(-1220)\"/g;
                            }
                            else {
                                $line =~
s/nbjob run/nbjob run --job-constraints \"wtime>$Models{timeout}{run}:kill(-1220)\"/g;
                            }

                            #print "Updated $line,$job_file\n";
                        }
                    }

                }

                elsif ( $line =~ /WorkArea\s+\/(.*)/ ) {
                    splice @taskfile, $x + 1, 0,
                      $depstr;    #Inserting DependsOn in the Regression Task file
                }
            }

            for my $x ( 0 .. $#taskfile ) {
                $line = $taskfile[$x];
                if ( defined $line ) {
                    if ( $line =~ /Environment/ )
                    { #FIXME when runscripts make sure two Environment directives are not present in nbtask file
                        if ( $taskfile[ $x + 2 ] =~ /setenv NB_POOLS FM_PDX/ ) {
                            splice @taskfile, $x, 4;
                        }
                    }
                }
            }

            #writing dependency in the regression task file

            open( TASKFILE, ">$task_file" )
              or die print
"gk-utils.pl was not able to grab the location of the runreg task file. Exiting. Please raise this issue with your local DA \n";
            print TASKFILE "@taskfile";
            close TASKFILE;

            if ( $VTMBTool->run( "wc -l $job_file", \@cmd_results2 ) == 0 ) {
                $VTMBTool->debug("Job File Found:$job_file");
                $test_count = $cmd_results2[-1];
                $test_count =~ s/\s.*$//;
                chomp($test_count);
            }
            else {
                $VTMBTool->error("Job File Wasn't found :$job_file");
                last;
            }

            # Set Initial Passing Rate by Eventtype
            if ( $GkEventType eq "RELEASE" ) {
                $pass_rate = $Models{nightly_pass_rate};
            }
            else {
                $pass_rate = 100;
            }

            #Logic to find out REGRESS_OUTPUT directory
            $regress_output = $task_file;

            $regress_output =~ s/(.*?)\/NBFILES.*/$1/g;
            $regress_nb_output = $regress_output . "/LOGFILES/";
            $regress_output    = $regress_output . "/REGRESS_OUTPUT/";

            ##Determine if Test Configuration has Passing Rate Override
            #if(defined $test_list->{PASS_RATE})
            # {
            #   $pass_rate = $test_list->{PASS_RATE};
            # }
            #else
            # {
            #   $pass_rate = 100;
            # }

            # If Job override GATING setting.
            # Gating can now handle GK Eventtype override.
            $gating =
              ( defined $test_list->{GATING} )
              ? &process_cfg_var( \$test_list, "GATING", $GkEventType )
              : 1;

            if ( defined $test_list->{EARLY_KILL_RGRS_CNT} ) {
                $job_early_kill = $test_list->{EARLY_KILL_RGRS_CNT};
            }

            else {
                undef $job_early_kill;
            }

            # Force Early kill behavior without updating the Job Hash.
            if (
                defined $Models{force_early_kill_regress}{ $ENV{'GK_CLUSTER'} }
                { $ENV{'GK_EVENTTYPE'} } )
            {
                $job_early_kill =
                  $Models{force_early_kill_regress}{ $ENV{'GK_CLUSTER'} }
                  { $ENV{'GK_EVENTTYPE'} };
            }

            #Add JobFile to a Jobs Structure
            $VTMBJob = new VTMBJob(
                CMDS            => $cmd,
                DUT             => $test_list->{DUT},
                NAME            => $test_list->{'NAME'},
                JOBFILE         => $job_file,
                DESC            => $test_list->{'DESC'},
                DEPENDENCY_FULL => [@test_dependency_full],
                ,
                DEPENDENCY => [@test_dependency],
                ,
                DEP_COND            => [@test_dependency_cond],
                REGRESS_OUTPUT      => $regress_output,
                REGRESS_NB_OUTPUT   => $regress_nb_output,
                SEND_MAIL           => $regress_mail_list,
                NBCLASS             => $test_list->{'NBCLASS'},
                MODEL               => $task_modelroot,
                TASK_NAME           => $task_name,
                TASK_PATH           => $task_path,
                TASK_FILE           => $task_file,
                REGRESS_COUNT       => $test_count,
                TEST_LIST           => $test_list->{LIST},
                PASS_RATE           => $pass_rate,
                GATING              => $gating,
                NBPOOL              => $job_nbpool,
                NBCLASS             => $job_nbclass,
                NBQSLOT             => $job_nbqslot,
                EARLY_KILL_RGRS_CNT => $job_early_kill,
                CMD_TYPE            => 'regress',
                SMART               => $smart,
            ) or die "Error Initializing VTMBJob Object. Report this bug to GK Owner\n";
            $VTMBTool->debug(
                "  Finished Generating NBFeeder Job File for $test_list->{'NAME'}");

            # Check Job NB Settings to ensure this is a valid Netbatch Configuration.
            # If this is a print commands invocation, turn error into warning.

            if ( !defined $netbatch_settings{$job_nbpool}{$job_nbclass}{$job_nbqslot} ) {
                $VTMBJob->check_netbatch_settings( $VTMBTool, $print_commands,
                    \%netbatch_settings );

                # Add the job to the HASH for record keeping purposes.
                push
                  @{ $netbatch_settings{$job_nbpool}{$job_nbclass}{$job_nbqslot}{JOBS} },
                  $VTMBJob->{NAME};
            }
            else {

                # Add the job to the HASH for record keeping purposes.
                push
                  @{ $netbatch_settings{$job_nbpool}{$job_nbclass}{$job_nbqslot}{JOBS} },
                  $VTMBJob->{NAME};
            }

## For Mock Turnin which runs as user, we will use the feeder created by IFEED
## For all other GK_EVENTTYPE we will create our own feeder if it doesn't exists
## Continue looping on @cmd_results if we haven' grabbed the NBfeeder Information.
            #                    if (   ( $GkEventType ne "MOCK" )
            #                        && ( defined $nbfeeder_conf ) )
            #                    {
            #                        last;
            #                    }
            #                    else {
            #                        last;
            #                    }
            #
            #                # Grab the Feeder Configuration and Work Area
        }
        else {

            my $rol;
            foreach $rol (@cmd_results) {
                if ( $rol =~ /No svn access/ ) {
                    if ( $svn_retry_count < 5 )    # 5 retries
                    {
                        $svn_retry_count++;
                        $VTMBTool->info(
"SVN issue encountered for DUT: $test_list->{DUT} \n Sleeping for 15 minutes"
                        );
                        sleep 15 * 60;
                        goto SVNRETRY;
                        last;
                    }
                }
            }

            # Create Job Object
            my $status =
              ( defined $test_list->{GATING} && $test_list->{GATING} == 0 )
              ? "NOT_GATING"
              : "FAILED";

#If stage is RELEASE, then we gotta make sure that GATING is 0, else retain GATING characteristics
#Default is always GATING = 1

            if ( $ENV{GK_EVENTTYPE} eq "release" ) {
                $test_list->{GATING} = $Models{nightly_gating}
                  if ( defined $Models{nightly_gating} );
            }

            $VTMBJob = new VTMBJob(
                CMDS              => $cmd,
                DUT               => $test_list->{DUT},
                NAME              => $test_list->{'NAME'},
                DESC              => $test_list->{'DESC'},
                STATUS            => $status,
                TASK_NAME         => $test_list->{'NAME'},
                TASK_PATH         => $task_path,
                MODEL             => $task_modelroot,
                NBPOOL            => $job_nbpool,
                REGRESS_OUTPUT    => $regress_output,
                REGRESS_NB_OUTPUT => $regress_nb_output,
                NBCLASS           => $job_nbclass,
                NBQSLOT           => $job_nbqslot,
                GATING            => $test_list->{'GATING'},
                FORCED_FAIL       => 1,
                CMD_TYPE          => 'regress',
                TASK_AREA         => $VTMBObj->get('TASK_AREA'),
                LOG_AREA          => $VTMBObj->get('LOG_AREA'),
                WORKAREA          => $VTMBObj->get('WORKAREA'),
                SMART             => $smart,
            ) or die "Error Initializing VTMBJob Object. Report this bug to GK Owner\n";

            my $runreg_dut = $test_list->{DUT};

            # Print Results of Error to log file
            open( LOGFILE, ">>$regress_path/GATEKEEPER/runreg_output_$runreg_dut.log" );
            print LOGFILE @cmd_results;
            close LOGFILE;

            #            foreach $line (@cmd_results) {
            #                chomp($line);
            #                $VTMBTool->warning("  $line");
            #            }

            # If this is a Release , mark as warning and but fail the job.

            if ( $GkEventType eq "RELEASE" ) {
                $VTMBTool->warning(
"\n\nRUNREG FAILED - DUT: $test_list->{'DUT'}: Runreg invocation failed for $test_list->{'DUT'} $test_list->{'LIST'} \nSee $regress_path/GATEKEEPER/runreg_output_$runreg_dut.log for details"
                );

             # For Mock Turnin we want to Add this job to the Hash, but expect it to Fail.
             # $VTMBJob->create_taskfile($VTMBObj);
                if ( defined $test_list->{TIMEOUT} ) {
                    $VTMBJob->create_taskfile( $VTMBObj, $test_list->{TIMEOUT} );
                }
                else {
                    $VTMBJob->create_taskfile( $VTMBObj, $Models{timeout}{build} );
                }
            }
            else {
                  my $email_list = $ENV{'GK_USER'} || $ENV{'USER'};
                  $email_list =~ s/\s+/,/g;
                  my $cc_list = $ENV{GK_ADMIN_EMAIL_LIST};
                  my $error_message = "\n\nRUNREG FAILED - DUT: $test_list->{'DUT'}: Runreg invocation failed for $test_list->{'DUT'} $test_list->{'LIST'} \nSee $regress_path/GATEKEEPER/runreg_output_$runreg_dut.log for details";
                  `echo "$error_message" | mail -s Runreg_invocation_failed -c $cc_list $email_list` if ($GkEventType =~ /FILTER|TURNIN/i);

                $VTMBTool->error($error_message);

                #  $VTMBJob->create_taskfile($VTMBObj);
                if ( defined $test_list->{TIMEOUT} ) {
                    $VTMBJob->create_taskfile( $VTMBObj, $test_list->{TIMEOUT} );
                }
                else {
                    $VTMBJob->create_taskfile( $VTMBObj, $Models{timeout}{build} );
                }
            }
        }
    }
    else {

        # Since this is for commands, filter the strings for readability.
        $cmd =~ s|$ENV{MODEL}/|\$MODEL/|g
          if ( defined $ENV{'MODEL'} );
        $cmd =~ s/$VTMBObj->{'TASK_PREFIX'}\.//g;

        #$cmd =~ s/-no_run.* -Q\s+\d+\s+//g;
        $cmd =~ s/-depends_on.* -depends_on-//g;
        if ( defined $test_list->{GATING} ) {
            $gating = $test_list->{GATING};
        }
        else {
            $gating = 1;
        }

        #Add JobFile to a Jobs Structure
        $VTMBJob = new VTMBJob(
            CMDS            => $cmd,
            DUT             => $test_list->{DUT},
            NAME            => $test_list->{'NAME'},
            DESC            => $test_list->{'DESC'},
            DEPENDENCY_FULL => [@test_dependency_full],
            DEPENDENCY      => [@test_dependency],
            ,
            DEP_COND          => [@test_dependency_cond],
            NBCLASS           => $test_list->{'NBCLASS'},
            TASK_NAME         => $task_name,
            TASK_PATH         => $task_path,
            REGRESS_OUTPUT    => $regress_output,
            REGRESS_NB_OUTPUT => $regress_nb_output,
            MODEL             => $task_modelroot,
            REGRESS_COUNT     => $test_count,
            PASS_RATE         => $pass_rate,
            GATING            => $gating,
            NBPOOL            => $job_nbpool,
            NBCLASS           => $job_nbclass,
            NBQSLOT           => $job_nbqslot,
            CMD_TYPE          => 'regress',
            SMART             => $smart,
        ) or die "Error Initializing VTMBJob Object. Report this bug to GK Owner\n";
        $VTMBTool->debug(
            "  Finished Generating NBFeeder Job File for $test_list->{'NAME'}");

    }

    # Add the Job and Task name to hash.
    $job_2_task_names{ $test_list->{'NAME'} } = $VTMBJob->{TASK_PATH};

    # Return the regressions Job
    return $VTMBJob;

}

#-------------------------------------------------------------------------------
# CreateNestedTask()
#   Merge all Existing tasks to create Nested Task
#-------------------------------------------------------------------------------
sub CreateNestedTask {

    # Display status and set up indentation
    $VTMBTool->indent_msg(0);
    $VTMBTool->info("Merging all individual tasks into 1 nested task");
    $VTMBTool->indent_msg(2);

    my $jobs;
    my $lines;
    my @sub_tasks_array;    # Store contents of all subtasks to create Nested Tasks
    my @temp;
    my $MaxWaitDefault = 100;
    my $time_2_live = ( defined $Models{nbtaskTTL} ) ? $Models{nbtaskTTL} : undef;

    # Create Job Object for Parent Task.
    $VTMBJob = new VTMBJob(
        NAME      => $VTMBObj->get('TASK_PREFIX'),
        WORKAREA  => $VTMBObj->get('MODEL') . "/GATEKEEPER/NBFeederTaskJobs",
        MODEL     => $VTMBObj->get('MODEL'),
        NBCLASS   => $ENV{'NBCLASS'},
        NBPOOL    => $ENV{'NBPOOL'},
        NBQSLOT   => $ENV{'NBQSLOT'},
        TASK_FILE => $VTMBObj->get('MODEL')
          . "/GATEKEEPER/NBFeederTaskJobs/"
          . $VTMBObj->get('TASK_PREFIX')
          . ".nbtask",
        TASK_NAME        => $VTMBObj->get('TASK_PREFIX'),
        TASK_PATH        => "/" . $VTMBObj->get('TASK_PREFIX'),
        TIME_2_LIVE      => $time_2_live,
        PARENT_TASK      => 1,
        DISABLE_NB_CHECK => $disable_nb_check,
    ) or die "Error Initializing VTMBJob Object. Report this bug to GK Owner\n";


    # Check Job NB Settings to ensure this is a valid Netbatch Configuration.
    # If this is a print commands invocation, turn error into warning.
    if ( !defined $netbatch_settings{ $VTMBJob->{NBPOOL} }{ $VTMBJob->{NBCLASS} }
        { $VTMBJob->{NBQSLOT} } )
    {
        $VTMBJob->check_netbatch_settings( $VTMBTool, $print_commands,
            \%netbatch_settings );

     # Commented out NBFlow team recommendation because it doesn't work on virtual pools.
     #$VTMBJob->validate_netbatch_settings($VTMBTool,$print_commands,\%netbatch_settings);
     # Add the job to the HASH for record keeping purposes.
        push @{ $netbatch_settings{ $VTMBJob->{NBPOOL} }{ $VTMBJob->{NBCLASS} }
              { $VTMBJob->{NBQSLOT} }{JOBS} }, $VTMBJob->{NAME};
    }
    else {

        # Add the job to the HASH for record keeping purposes.
        push @{ $netbatch_settings{ $VTMBJob->{NBPOOL} }{ $VTMBJob->{NBCLASS} }
              { $VTMBJob->{NBQSLOT} }{JOBS} }, $VTMBJob->{NAME};
    }

    # Copy the contents of all Tasks files into temp variable.
    # Only perform this copy if the Task has not been submitted to NBFeeder
    foreach $jobs (@VTMBJobs) {

        if ( ( !defined $jobs->{NB_STATUS} ) && ( defined $jobs->{TASK_FILE} ) ) {

            # Set Task Name Environment variable for Procmon
            my $nb_task_name = $jobs->{TASK_NAME};
            $nb_task_name =~ s/\.\d+\.([^.]+)$/.$ENV{'GK_STEP'}.$1/;
            my $gk_task_name       = $jobs->{NAME};
            my $has_stage_name     = 0;
            my $subtask_line_count = 0;
            open( SUB_TASK, "$jobs->{TASK_FILE}" )
              || die "File $jobs->{TASK_FILE} does not exists";
            while (<SUB_TASK>) {
                chomp;
                my $line = $_;
                $has_stage_name = 1 if ( $line =~ /Setenv\s+GK_STAGE_NAME\s/i );

      # This is a hack to work around Lint Issue with Parallel Jobs by overriding AUTO_REQ
                if (   ( $line =~ /autoreq/ )
                    && ( defined $jobs->{JOB_TYPE} )
                    && ( $jobs->{JOB_TYPE} eq "SPAWN" )
                    && ( defined $jobs->{SPAWN_AUTO_REQ} ) )
                {
                    $line =~ s/attempts.*$/$jobs->{SPAWN_AUTO_REQ}/;
                    $line .= "\n";
                }

                # This is a Hack until Ifeed and NBFeeder API's get updated.
                if ( $line =~ /Queue/ ) {
                    if (
                        (
                               !defined $jobs->{JOB_ENV}->[0]
                            && !defined $jobs->{HAS_ENV_BLOCK}
                        )
                        && !$has_stage_name
                      )
                    {

                   # For SPAWN Task, there could be a { on the same line as the Task Name.
                        if ( $jobs->{JOB_TYPE} eq "SPAWN" ) {
                            $nb_task_name =~ s/{//;
                        }
                        push @sub_tasks_array, "\tEnvironment\n";
                        push @sub_tasks_array, "\t{\n";
                        push @sub_tasks_array, "\tSetenv __NB_TASK_NAME $nb_task_name\n";
                        push @sub_tasks_array, "\tSetenv GK_STAGE_NAME $gk_task_name\n";
                        #This is to handle trex spawn task issue for cth hybrid flow
								push @sub_tasks_array, "\tSetenv PROJECT CTH\n" if ($jobs->{TASK_FILE} =~ /nbtask_conf/);
                        push @sub_tasks_array, "\t}\n";
                    }
                    push @sub_tasks_array, "$line\n";
                }
                elsif ( $line =~ /Policy WorkAreaIsMissing_Mail_or_Stop/ ) {
                    for ( my $i = 0 ; $i < 9 ; $i++ ) {
                        my $next_line = <SUB_TASK>;
                    }
                }
                elsif ( $line =~ /Policy FreqCov_Files_Collector/ ) {
                    for ( my $i = 0 ; $i < 14 ; $i++ ) {
                        my $next_line = <SUB_TASK>;
                    }
                }
                elsif ( $line =~ /Policy Inca_Files_Collector/ ) {
                    for ( my $i = 0 ; $i < 14 ; $i++ ) {
                        my $next_line = <SUB_TASK>;
                    }
                }
                else {

                    # Added --work-dir /netbatch to all regression submission args.
                    if (   ( $line =~ /^\s*SubmissionArgs/ )
                        && ( defined $jobs->{REGRESS_COUNT} ) )
                    {
                        $line .= " --work-dir /netbatch ";
                    }

# This is a hack to workaround a deprecated task variable in version of NBFlow after 1.4.1
                    if ( $line =~ /TaskReportUpdateFrequency/ ) {

                        # For Version of NBFlow  2.0 or later
                        if ( $ENV{NBFEEDER_VERSION} =~ /^2/ ) {
                            $line = "\n";
                        }
                    }
                    if ( $line =~ /UpdateFrequency|SubmitFrequency/ ) {

                        # For Version of NBFlow  2.0 or later
                        if ( $ENV{NBFEEDER_VERSION} =~ /^2/ ) {
                            $line = "\n";
                        }
                    }

         # This is a hack until Ifeed provides a commandline switch to override MaxWaiting
                    if ( defined $jobs->{REGRESS_COUNT}
                        && ( $line =~ /MaxWaiting\s*(\d+)/ ) )
                    {

    # Override the default trickle setting
    # For Mock, Release, Post Release, trickle set to 100(MaxWaitDefault) is sufficient.
    # For processes in the Filter or Integration Pipeline , MaxWait set to number of test.
    # In GK Utils CFG, user can override MaxWait for all events.
                        my $MaxWait = $1;
                        if ( !defined $Models{task_max_wait} ) {
                            if ( $GkEventType =~ /MOCK|RELEASE|POST-RELEASE/ ) {
                                $line =~ s/$MaxWait/$MaxWaitDefault/;
                            }
                            else {
                                $line =~ s/$MaxWait/$jobs->{REGRESS_COUNT}/;
                            }
                        }
                        else {
                            $line =~ s/$MaxWait/$Models{task_max_wait}/;
                        }
                        push @sub_tasks_array, "$line\n";
                    }
                    else {
                        push @sub_tasks_array, "$line\n";
                    }
                }
                $subtask_line_count++;
            }
            close(SUB_TASK);

            # Added newline to create space between tasks.
            push @sub_tasks_array, "\n";
            $VTMBTool->info("Task file $jobs->{NAME} contains $subtask_line_count lines");
        }
        if ( ( !defined $jobs->{NB_STATUS} ) && ( !defined $jobs->{TASK_FILE} ) ) {
            $VTMBTool->error("Task file for  $jobs->{NAME} is not defined.");
            $VTMBTool->check_errors();
        }

    }

    # Create Parent Task
    $VTMBJob->create_parent_taskfile( \@sub_tasks_array );

    # Add Parent Task to Jobs Hash
    # Only add if Parent Task has not been submitted to NBFeeder
    if ( !defined $VTMBJobs[0]->{PARENT_TASK} ) {
        push @temp, $VTMBJob;
        @VTMBJobs = ( @temp, @VTMBJobs );
    }

    # Current version of API's does not support including subtask in a parent task.
    # We will do this thru brute force.
    $VTMBTool->movefile( "$VTMBJob->{TASK_FILE}", "$VTMBJob->{TASK_FILE}.bak" );

    open( PARENT_TASK_BAK, "$VTMBJob->{TASK_FILE}.bak" )
      || die "File $VTMBJob->{TASK_FILE}.bak does not exist";
    open( PARENT_TASK, ">$VTMBJob->{TASK_FILE}" );
    while (<PARENT_TASK_BAK>) {
        if ( $_ =~ /#\s*REPLACE_WITH_SUB_TASK/ ) {
            foreach $lines (@sub_tasks_array) {
                print PARENT_TASK "\t$lines";
            }
        }
        else {
            print PARENT_TASK $_;
        }
    }
    close(PARENT_TASK_BAK);
    close(PARENT_TASK);

    # Return
    return @VTMBJobs;
}

#-------------------------------------------------------------------------------
# PrintCommands()
#   Dump the commands to STDOUT.
#-------------------------------------------------------------------------------
sub PrintCommands {

    # Display status and set up indentation
    $VTMBTool->indent_msg(2);
    $VTMBTool->debug("Dumping Commands");
    $VTMBTool->indent_msg(0);
    my %jobs_printed = ();
    my %level        = ();
    my %all_names    = ();
    if ( defined $ENV{'GK_RECIPE_PERL'} && $ENV{'GK_RECIPE_PERL'} ) {
        PrintRecipePerl();
    }
    else {
        foreach my $jobs (@VTMBJobs) {
            $all_names{ $jobs->{NAME} } = 1;
        }
        $VTMBTool->set( 'QUIET', 0 ) if !$ENV{'DISABLE_QUIET_MODE'};
        foreach my $jobs (@VTMBJobs) {
            if ( !defined $jobs->{DEPENDENCY}->[0] ) {
                $level{ $jobs->{NAME} } = 0;
                RecPrintCommands( $jobs, \%level, \%jobs_printed, \%all_names );
            }
        }
    }
    $VTMBTool->set( 'QUIET', 1 ) if !$ENV{'DISABLE_QUIET_MODE'};

    # Data Dumper
    my $vtmb_dump =
      $VTMBObj->get('MODEL') . "/GATEKEEPER" . "/vtmbjob.$ENV{'GK_EVENTTYPE'}.pl";
    open( FD, ">$vtmb_dump" );
    my $VTMBJobs = \@VTMBJobs;
    local $Data::Dumper::Purity = 1;
    print FD Data::Dumper->Dump( [$VTMBJobs], ["VTMBJobs"] );
    close FD;
}

sub RecPrintCommands {
    my ( $jobs, $level, $jobs_printed, $all_names ) = @_;
    for ( my $i = 0 ; $i < $level->{ $jobs->{NAME} } ; $i++ ) {
        print "\t";
    }

    if ( defined $jobs->{GATING} && $jobs->{GATING} == 0 ) {
        $VTMBTool->info(" $jobs->{CMDS}\t\t[NOT GATING]");
    }
    else {
        $VTMBTool->info(" $jobs->{CMDS}");
    }
    $jobs_printed->{ $jobs->{NAME} } = 1;
    foreach my $next_job (@VTMBJobs) {
        my $to_print  = 1;
        my $max_level = 0;
        if ( defined $next_job->{DEPENDENCY}->[0] ) {
            foreach my $dep ( @{ $next_job->{DEPENDENCY} } ) {
                $dep =~ s/.*\.//;
                next unless exists $all_names->{$dep};
                if ( !exists $jobs_printed->{$dep} ) {
                    $to_print = 0;
                }
                else {
                    $max_level =
                      ( $level->{$dep} > $max_level ) ? $level->{$dep} : $max_level;
                }
            }
            next unless $to_print;
            my $dependency = $next_job->{DEPENDENCY}->[0];
            $dependency =~ s/.*\.//;
            if ( !exists $jobs_printed->{ $next_job->{NAME} } ) {
                $level->{ $next_job->{NAME} }        = $max_level + 1;
                $jobs_printed->{ $next_job->{NAME} } = 1;
                RecPrintCommands( $next_job, $level, $jobs_printed, $all_names );
            }
        }
    }
}

sub PrintRecipePerl {
    print "\@GK_RECIPE = (\n";
    foreach my $jobs (@VTMBJobs) {
        my $name = $jobs->{NAME};
        my $dut  = $jobs->{DUT};
        next if $name =~ /remove_nbfeeder_logs/;
        next if $name =~ /NBFEEDER_ENV_DUMP/;

        print "\t{\n";
        print "\t\t'NAME' => '$name',\n";
        print "\t\t'DUT'  => '$dut',\n";
        my $cmd = $jobs->{CMDS};
        $cmd =~ s/\'/\\'/g;
        print "\t\t'CMD' => '$cmd',\n";
        print "\t\t'GATING' => $jobs->{GATING},\n";
        if ( defined $jobs->{JOB_TYPE} ) {
            print "\t\t'JOB_TYPE' => \'$jobs->{JOB_TYPE}\',\n";
        }
        print "\t\t'DEPENDENCY'   => {";
        if ( defined $jobs->{DEPENDENCY} ) {
            my $ind = 0;
            foreach my $dep ( @{ $jobs->{DEPENDENCY} } ) {
                $dep =~ s/.*\.//;
                print "'$dep' => \"$jobs->{DEP_COND}->[$ind]\",";
            }
        }
        print "},\n";
        print "\t},\n";
    }
    print ");\n";
}

#-------------------------------------------------------------------------------
# LaunchMonitorJobs()
#   Launch Jobs, Monitor Status, and Clean up if Interrupt Occurs
#-------------------------------------------------------------------------------
sub LaunchMonitorJobs {

    # Display status and set up indentation
    $VTMBTool->indent_msg(0);
    $VTMBTool->info("Launching Jobs thru NBFeeder and Monitoring");
    $VTMBTool->indent_msg(2);

    my ( $jobs, $jobs_post );

    #   my $response;
    my $loop_times;

    #   my ($Status,$LocalWait,$RemoteWait,$Running,$Successful,$Failed);
    my $jobs_running = 0;
    my $launch_post  = 0;
    my %jobs_completed;
    my $feeder;
    my $waiting;
    my $msg;
    my $cama_unreg;
    my @cama_unreg_output;
    my $feeder_lost;

    # Setup Signal Handler to Correctly clean up jobs
    local $SIG{'INT'}  = \&signal_handler;    # Same as kill -2  pid
    local $SIG{'KILL'} = \&signal_handler;    # Same as kill -9  pid
    local $SIG{'USR1'} = \&signal_handler;    # Same as kill -10 pid
         #  Used to exit gracefully with non zero exit code
    local $SIG{'PIPE'} = \&signal_handler;    # Same as kill -13 pid
    local $SIG{'ALRM'} = \&signal_handler;    # Same as kill -14 pid
    local $SIG{'TERM'} = \&signal_handler;    # Same as kill -15 pid
                                              # Used to exit because a build job failed.
    local $SIG{'URG'}  = \&signal_handler;    # Same as kill -23 pid
         # Used to exit because NBFeeder did not pick up a job.
         # If NBFeeder doesn't accept task, we are DOA.
    local $SIG{'XCPU'} = \&signal_handler; # Same as kill -24 pid
                                           # Used to exit an EARLY KILL limit was reached.
    local $SIG{'ILL'}  = \&signal_handler; # Same as kill -4

    # In Mockturnin we need to clean stuff in the target directory as a workaround
    # to an elusive VCS bug related to incremental build
    if ( $GkEventType eq "MOCK" ) {
        &CleanTargetDirectory();
    }

    # Set Feeder Host based on GK_FEEDER_HOST setting
    $VTMBJobs[0]->set( 'FEEDER_HOST', $ENV{'GK_FEEDER_HOST'} );

    ### For the FEEDER Area Specified.
    ### Create a NBFEEDER configuration File.
    $nbfeeder_ward = abs_path("$ENV{'GK_FEEDER_WORK_AREA'}/$ENV{'USER'}");
    $VTMBTool->create_directories($nbfeeder_ward);
    $nbfeeder_conf = $VTMBJobs[0]->create_config_file($nbfeeder_ward);
    $VTMBTool->info ("Feeder Host Machine = $ENV{GK_FEEDER_HOST}");
    $VTMBTool->info ("Feeder Work Area    = $nbfeeder_ward");
############################################################ REMOVE 10/5/2010 Code is redundant
###    # Determine which feeder we will use, one possibly created and configured by IFEED.
###    # or one created and configured by this script.
###    if($GkEventType ne "MOCK")
###     {
###        $nbfeeder_ward = abs_path("$ENV{'GK_FEEDER_WORK_AREA'}/$ENV{'USER'}");
###        $VTMBTool->create_directories($nbfeeder_ward);
###        $nbfeeder_conf = $VTMBJobs[0]->create_config_file($nbfeeder_ward);
###     }
###    else
###     {
###        $nbfeeder_ward = abs_path("$ENV{'GK_FEEDER_WORK_AREA'}/$ENV{'USER'}");
###        $VTMBTool->create_directories($nbfeeder_ward);
###        $nbfeeder_conf = $VTMBJobs[0]->create_config_file($nbfeeder_ward);
###     }
############################################################

    # Get NBFeeder running on this $HOST`
    # If they match expected configuration, use it.

    $VTMBJobs[0]->set('FEEDER_NAME', $ENV{GK_FEEDER_NAME} );
    $VTMBTool->info ("Feeder Name    = $ENV{GK_FEEDER_NAME}");
    $feeder = $VTMBJobs[0]->get_nbfeeders( $VTMBTool, $nbfeeder_ward, $nbfeeder_conf,  );
    $VTMBTool->debug ("Found feeder: " . Dumper \$feeder);

    #  Commented this code out because it is contain in the else clause below.
    #  Removed after March 31, 2010.
    #   # Start feeder if not running. get_nbfeeders needs to be rerun after the feeder is
    #   # started.
    #   if((!defined $feeder) || ($feeder->{STATUS} ne "Running")) {
    #      $VTMBTool->info("No Running Feeder Found. Starting new one on $ENV{'HOST'}");
    #      $VTMBJobs[0]->start_feeder($VTMBTool,$nbfeeder_ward,$nbfeeder_conf);
    #      $feeder = $VTMBJobs[0]->get_nbfeeders($VTMBTool,$nbfeeder_ward,$nbfeeder_conf);
    #   }

    if (   ( defined $feeder )
        && ( $feeder->{STATUS} eq "Running" ) )    # Feeder Already running
    {

# Check if existing jobs(Zombie) are running and kill them if found.
# I do not believe this code is needed any more.
# Since we changed task name to contain $PID, it is impossible to ever satisfy this condition
# of finding an existing task with the same name.
# Trap Added 10/09/2009. Remove in 11/1/2009
        foreach $jobs (@VTMBJobs) {
            next
              if ( defined $jobs->{'STATUS'}
                && ( $jobs->{'STATUS'} eq "FAILED" || $jobs->{'STATUS'} eq "NOT_GATING" )
              );
            $jobs->set( 'FEEDER_TARGET', $feeder->{'FEEDER_TARGET'} );
            $jobs->task_status( $VTMBTool, $nbfeeder_ward, $nbfeeder_conf );
            if ( defined $jobs->{TASK_ID} ) {

                $VTMBTool->info("Task ID is $jobs->{TASK_ID} \n");

                # This is the trap code
                $VTMBTool->info(
"THIS IS REDUNDANT CODE WHICH IS NO LONGER NEEDED. PLEASE CONTACT GK Admin if hit."
                );
                $VTMBTool->check_errors();
                if (
                    $VTMBTool->run(
                        "nbtask delete --target $feeder->{FEEDER_TARGET} $jobs->{TASK_ID}"
                    ) == 0
                  )
                {
                    $VTMBTool->info("Deleted Task:$jobs->{TASK_NAME} ");
                }
                else {
                    $VTMBTool->error("Could'nt Deleted Task:$jobs->{TASK_NAME} ");

                    # Terminate if errors encountered
                    $VTMBTool->check_errors();
                }
            }
        }
    }
    else {

        # Starting a new Feeder
        if ( (defined $VTMBJobs[0]->{'FEEDER_HOST'}) && ($ENV{GK_EVENTTYPE} ne 'mock') ) {
            $VTMBTool->info(
"No Running Feeder Found on External Machine. Starting new one on $VTMBJobs[0]->{'FEEDER_HOST'}"
            );
        }
        else {
            $VTMBTool->info("No Running Feeder Found. Starting new one on $ENV{'HOST'}");
        }
        if ($ENV{GK_EVENTTYPE} eq 'mock') {
            my $feeder_host = &get_feeder_host(\%Models);
            if (!defined $feeder_host) {
                $VTMBTool->error( "Could not determine feeder_host. Please contact FEChecks admins");
                $VTMBTool->check_errors;
            }
            # Set Feeder Host based on GK_FEEDER_HOST setting
            $VTMBJobs[0]->set( 'FEEDER_HOST', $feeder_host );
        }
        $VTMBTool->info("NBFEEDER WARD : $nbfeeder_ward");
        $VTMBTool->info("NBFEEDER CONF : $nbfeeder_conf");
        $VTMBTool->info("NBFEEDER INSTANCE : $feeder_instance");
        $VTMBTool->info("NBFEEDER MAX : $feeder_max");
        $VTMBJobs[0]->start_feeder( $VTMBTool, $nbfeeder_ward, $nbfeeder_conf,$feeder_instance,$feeder_max);
        $feeder =  $VTMBJobs[0]->get_nbfeeders( $VTMBTool, $nbfeeder_ward, $nbfeeder_conf );
        $VTMBTool->info("NBFEEDER : $feeder");

    }

    # Parent task has to have FEEDER_TARGET set to load the task.
    #  Also export the FEEDER target for use by other tools.
    if ( !defined $feeder->{'FEEDER_TARGET'} ) {
        $VTMBTool->error("FEEDER TARGET is not defined. Contact GK Admin");
        $VTMBTool->check_errors();
    }
    $VTMBJobs[0]->set( 'FEEDER_TARGET', $feeder->{'FEEDER_TARGET'} );
    $ENV{'FEEDER_TARGET'} = $feeder->{'FEEDER_TARGET'};

    # Dump the Environment prior to NB Job submissions for comparison
    $VTMBTool->run(" env > $ENV{'MODEL'}/GATEKEEPER/PRE_NBFEEDER_ENV_DUMP");

    # Launch the Parent Task
    $VTMBJobs[0]
      ->submit_parent_task( $VTMBTool, $nbfeeder_ward, $nbfeeder_conf, \@VTMBJobs );

# Confirm the Parent Task was completed loaded into the Feeder, if not kill the entire process.
# Code added to handle case of task not being picked up by Feeder.
# For this case, we want to kill the entire process, restart or investigate.
# Kill is done by signal handler to ensure no zombie jobs are left.
    if ( !defined $VTMBJobs[0]->{'TASK_ID'} ) {
        kill( 4, $ENV{'MY_PID'} );
    }
    else {

        # Sect Flag that jobs have been launched and also number of jobs.
        $jobs_running  = scalar(@VTMBJobs) - 1;    # Subtract Parent Task.
        $jobs_launched = 1;
    }

#   # Launch the Job using Feeder WARD and Configuration
#   foreach $jobs (@VTMBJobs)
#    {
#      if (defined $jobs->{'STATUS'} && ($jobs->{'STATUS'} eq "FAILED" || $jobs->{'STATUS'} eq "NOT_GATING"))
#      {
#         $jobs_completed{$jobs->{TASK_NAME}} = 1;
#         next;
#      }
#
#      $jobs->submit_tasks($VTMBTool,$nbfeeder_ward,$nbfeeder_conf);
#
#      # Code added to handle case of task not being picked up by Feeder.
#      # For this case, we want to kill the entire process, restart or investigate.
#      # Kill is done by signal handler to ensure no zombie jobs are left.
#      if(!defined $jobs->{'TASK_ID'})
#       {
#         kill(4,$ENV{'MY_PID'});
#       }
#      else
#       {
#         # Increment Job Counters on each successful submissions
#         $jobs_running++;
#         $jobs_launched = 1;
#       }
#    }

    # Setup Alarm to Catch Run a Run Away Process and kill jobs
    $timeout = $Models{timeout}{ $ENV{'GK_CLUSTER'} } * 3600;
    alarm $timeout;
    $VTMBTool->info("Alarm will Fire in $timeout seconds");

    # Check The Jobs Status and Exit when Completed.
    our %notify_build_mon;

    #Obtain the build monitors list from gkconfigs if not mentioned in gk-utils recipe file
    my $dut_owner_map_file;
    if (defined $Models{dut_owner_map_file} &&
             -f $Models{dut_owner_map_file}){
        $dut_owner_map_file = $Models{dut_owner_map_file};
    }

    # Set dut_owner_map file: Different for MOCK than other stages
    if (defined $ENV{GK_QB_DUT_OWNER_MAP} && $GkEventType eq "MOCK"
          && -f $ENV{GK_QB_DUT_OWNER_MAP}){
        $dut_owner_map_file = $ENV{GK_QB_DUT_OWNER_MAP};
    }

    foreach my $task_jobs (@VTMBJobs) {
      my $mail_list;
      if (!defined $task_jobs->{SEND_MAIL}) {
        if (-e $dut_owner_map_file) {
          open (ALERT, "< $dut_owner_map_file") ;
             my $dut = $task_jobs->{DUT};
                  chomp ($dut);
                  while (my $line = <ALERT>) {
                  if ($line =~ /^$dut\s*:\s*(.*)/i){
                  $mail_list = $1;
                  chomp($mail_list);
                  $task_jobs->{SEND_MAIL} = $mail_list;
             }
          }
        }
      }
    }

    while ( $jobs_running > 0 ) {

        # Write the status of each job to report file.
        $VTMBTool->write_report( \@VTMBJobs, $job_report );

        # If any Job Fails and Status has not been emailed. Sent the email once;
        my ($jobs_failed) = 0;
        foreach $jobs (@VTMBJobs) {
            if (   ( $jobs->{FAILING} ne "" )
                && ( $jobs->{FAILING} > 0 )
                && ( $jobs->{GATING} )
                && ( !$jobs->{EMAIL_ON_FAIL} )
                && ( !defined $jobs->{PARENT_TASK} ) )
            {

                # Set Flags
                $jobs_failed = 1;
                $jobs->set( 'EMAIL_ON_FAIL', 1 );
            }
        }


    if ($GkEventType eq "TURNIN" || $GkEventType eq "MOCK") {
        #Notify build monitors if build commands fail during integrate & mock phase
        foreach $jobs (@VTMBJobs) {
          my $message;
          my $mail_list;
          if ( ( $jobs->{FAILING} ne "" ) && ( $jobs->{FAILING} > 0 )
             && ( $jobs->{GATING} ) && ( defined $jobs->{SEND_MAIL} ) )
            {
              my $task_name = $jobs->{NAME};
              next if ($notify_build_mon{$task_name}{seen} == 1);

              $notify_build_mon{$task_name}{email} = $jobs->{SEND_MAIL};
              chomp ($jobs->{DUT});
              my $message = "Project: $ENV{PROJECT}\n";
              $message .= "Pipeline: $ENV{GK_CLUSTER}\n";
              $message .= "You are listed as the Build Monitor for the dut: ".
                          "$jobs->{DUT}.\n\n";
              $message .= "The job ".$jobs->{NAME}." failed during Integrate ".
                          "Stage for TurninID: $ENV{GK_TURNIN_ID}. \n\n"
                              if ($GkEventType eq "TURNIN");
              $message .= "The job ".$jobs->{NAME}." failed during QuickBuild.".
                          "\n\n" if ($GkEventType eq "MOCK");

              $message .= "Path to Failure log: \n";
              $message .= "$ENV{MODEL}/GATEKEEPER/NBLOG:$task_name\n";
              $VTMBJobs[0]->notify_build_monitors(
                  $notify_build_mon{$task_name}{email}, $ENV{GK_USER}, $message,
                      $task_name) if (defined $ENV{GK_TURNIN_ID} ||
                                     (defined $ENV{GK_QB_DUT_OWNER_MAP}
                                       && -f $ENV{GK_QB_DUT_OWNER_MAP}
                                       && $GkEventType eq "MOCK"));
              $notify_build_mon{$task_name}{seen} = 1;
           }
        }
    }

        #Do not look for failures and send mail if it is PreBuildRegress
        if ( $jobs_failed && !$PreBuildRegress ) {

            # Lets get the failures from gk_report.txt
            my ( $message, $report_txt, $email_list, $subject, $cc_list ) =
              ( "", "", "", "", "" );
            my $failures = 0;
            open( GK_REPORT_TXT, $job_report );
            while (<GK_REPORT_TXT>) {
                if (/Failure Reports/) {
                    $failures = 1;
                }
                if ($failures) {
                    $report_txt .= $_;
                }
            }
            close(GK_REPORT_TXT);

            # Create Email list for notification.
            $email_list = $ENV{'GK_USER'} || $ENV{'USER'};
            $email_list =~ s/\s+/,/g;

            # Mock Turnin Message
            if ( $GkEventType eq "MOCK" ) {
                $message = "Your Mock turnin has experienced a failure.\n";
                $message .=
"The Mock Turnin is still running, but it is recommended you look at the failures.\n\n";
                $message .= $report_txt;
                $subject =
"$ENV{'GK_CLUSTER'} $ENV{'GK_STEP'} Mock Turnin Failure Encountered: $ENV{'MODEL'}";
                $VTMBJobs[0]
                  ->job_status_email( $email_list, $ENV{'USER'}, $cc_list, $subject,
                    $message );
            }

            # Turnin Message
            if ( ( $GkEventType eq "TURNIN" ) || ( $GkEventType eq "FILTER" ) ) {

# Augment Email List with pipeline admins for Officlal GK runs. During commandline testing, do not add admins to list.
                if (   ( defined $ENV{'GK_ADMIN_EMAIL_LIST'} )
                    && ( defined $ENV{'GK_TURNIN_ID'} )
                    && ( defined $ENV{'GK_USER'} ) )
                {
                    $cc_list = "," . $ENV{'GK_ADMIN_EMAIL_LIST'};
                }
                $message =
                    "Your Turnin("
                  . $VTMBObj->get('DIR_NAME')
                  . ") has experienced a failure.\n";
                $message .=
"The Turnin is still running, but it is recommended you look at the failures.\n\n";
                $message .=
"If you know this turnin is bad, please remove it from the GK pipeline using the following command\n";
                $message .= "turnin -s $ENV{'GK_STEP'} -c $ENV{'GK_CLUSTER'} -cancel "
                  . $VTMBObj->get('DIR_NUM') . "\n\n";
                $message .=
"A complete report can be generated using the following command: turnininfo "
                  . $VTMBObj->get('DIR_NUM')
                  . " -report\n\n";
                $message .= $report_txt;
                $subject =
"$ENV{'GK_CLUSTER'} $ENV{'GK_STEP'} Failure Encountered for $GkEventType "
                  . $VTMBObj->get('DIR_NUM') . "\n";
                $VTMBJobs[0]
                  ->job_status_email( $email_list, $ENV{'USER'}, $cc_list, $subject,
                    $message );
            }
        }

        # Send Notification NBFEEDER Connection is lost.
        if ( $GkEventType eq "MOCK" ) {
            $feeder_lost = 0;
            foreach $jobs (@VTMBJobs) {
                if ( ( $jobs->{FEEDER_LOST} >= 1 ) && ( !defined $jobs->{PARENT_TASK} ) )
                {

                    # Set Flag to Indicate Connection to NBFeeder has been lost.
                    $feeder_lost = 1;
                }
            }

            # Send Message if NBFeeder Connection is lost
            if ( ($feeder_lost) && ( $VTMBJobs[0]->{FEEDER_LOST} == 0 ) ) {
                $VTMBJobs[0]->set( 'FEEDER_LOST', 1 );
                my ( $message, $email_list, $subject, $cc_list ) = ( "", "", "", "" );

                # Create Email list for notification.
                $email_list = $ENV{'GK_USER'} || $ENV{'USER'};
                $email_list =~ s/\s+/,/g;

                $message = "Your MockTurnin running at : $ENV{'MODEL'} .\n";
                $message .=
" might have Lost connnection to its NBFeeder at $VTMBJobs[0]->{FEEDER_TARGET}.\n\n";
                $message .= "Please bring up Mock Turnin NBFlow GUI as follows.\n";
                $message .= "/nfs/site/gen/adm/netbatch/nbfeeder/install/$ENV{NBFEEDER_VERSION}/bin/nbflow\n\n";
                $message .=
" In the Feeder List, highlight the feeder : $VTMBJobs[0]->{FEEDER_TARGET}\n";
                $message .=
" Click on the Play button to re-activate the Feeder which may have gone down.\n";
                $message .=
" It will take a few minutes but you should see the feeder go from Stopped to Running.\n\n";
                $subject =
"$ENV{'GK_CLUSTER'} $ENV{'GK_STEP'} Mock Turnin might have Lost Feeder Connection\n\n";
                $VTMBJobs[0]
                  ->job_status_email( $email_list, $ENV{'USER'}, $cc_list, $subject,
                    $message );
            }

            # Unset Feeder Lost setting in Parent Task
            if ( ( $feeder_lost == 0 ) && ( $VTMBJobs[0]->{FEEDER_LOST} == 1 ) ) {
                $VTMBJobs[0]->set( 'FEEDER_LOST', 0 );
            }

        }

        # After report is written out, check to see if any build jobs have failed.
        # If so, kill the process.
        # However, do not kill if these is a RELEASE or MOCK TURNIN.
        if ( ( $GkEventType ne "MOCK" ) && ( $GkEventType ne "RELEASE" ) ) {
            foreach $jobs (@VTMBJobs) {
                if ( !defined $jobs->{REGRESS_COUNT} ) {

                    # Early Kill for Build Jobs
                    if (   ( defined $jobs->{EARLY_KILL} && $jobs->{EARLY_KILL} == 1 )
                        && ( defined $jobs->{STATUS} )
                        && ( $jobs->{STATUS} eq "FAILED" ) )
                    {

# Until we get a modification from GK for a pipeline to determine when it is in NoJeClear,NoJeClearFilter, or Possibly Freeze Mode.
# This Capability will be enabled Globally or by Cluster and GK_EVENTTYPE.
# Globally Defined
                        if (   ( defined $Models{early_kill}{all} )
                            && ( $Models{early_kill}{all} == 1 ) )
                        {
                            kill( 23, $ENV{'MY_PID'} );
                        }

                        # Defined by Cluster and GK_EVENTYPE
                        if (
                            (
                                defined $Models{early_kill}{ $ENV{'GK_CLUSTER'} }
                                { $ENV{'GK_EVENTTYPE'} }
                            )
                            && ( $Models{early_kill}{ $ENV{'GK_CLUSTER'} }
                                { $ENV{'GK_EVENTTYPE'} } == 1 )
                          )
                        {
                            kill( 23, $ENV{'MY_PID'} );
                        }
                    }
                }
                else {

                    # Early Kill for Regressions
                    if (   defined $jobs->{EARLY_KILL_RGRS_CNT}
                        && ( $jobs->{NB_STATUS} eq "Running" )
                        && ( $jobs->{FAILING} >= $jobs->{EARLY_KILL_RGRS_CNT} ) )
                    {
                        kill( 24, $ENV{'MY_PID'} );
                    }
                }
            }
        }

        # Sleep for X cycles in seconds between checking the status of jobs.
        # Default is 10 minutes/600 seconds between checking the status of Jobs.
        # This can be overridden in the configuration file GkUtils.${PROJECT}.cfg
        if ( defined $Models{sleep_cycle} ) {
            $sleep_cycle = $Models{sleep_cycle};
        }
        if ( $VTMBCmdline->value('-sleep') ) {
            $sleep_cycle = $VTMBCmdline->value('-sleep');
		    }
	    	#Added to obtain the sleep option given by user during quickbuild.
        if ( defined $ENV{QB_SLEEP_CYCLE} ) {
            $sleep_cycle = $ENV{QB_SLEEP_CYCLE};
        }
        sleep $sleep_cycle;

        $VTMBJobs[0]->parent_task_status( $VTMBTool, \@VTMBJobs );

        #Check the Jobs Status
        # $VTMBTool->blank();
        foreach $jobs (@VTMBJobs) {
            if ( !defined $jobs->{PARENT_TASK} ) {
                if ( !defined $jobs->{STATUS} ) {
                    $jobs->task_status( $VTMBTool, $nbfeeder_ward, $nbfeeder_conf );

                    #$VTMBTool->log("Task $jobs->{TASK_NAME}:$jobs->{NB_STATUS}");
                }

               # For Jobs which just completed, print to STDOUT Job Description and Status
                if (   ( defined $jobs->{STATUS} )
                    && ( !defined $jobs_completed{ $jobs->{TASK_NAME} } ) )
                {
                    $VTMBTool->set( 'QUIET', 1 ) if !$ENV{'DISABLE_QUIET_MODE'};
                    $jobs_completed{ $jobs->{TASK_NAME} } = 1;
                    $jobs->check_task_job_status($VTMBTool);
                    $VTMBTool->set( 'QUIET', 1 ) if !$ENV{'DISABLE_QUIET_MODE'};
                    $jobs_running--;

 # Handle Task which may be spawned from other tasks.
 # Will only go thru this loop once, no need to unset SPAWN_TASK to prevent infinite loop.
                    if (
                        defined $jobs->{SPAWN_TASK}->[0]
                        && (   $jobs->{STATUS} eq "PASSED"
                            || $jobs->{STATUS} eq "NOT_GATING" )
                      )
                    {
                        my $index = 0;
                        foreach my $spawn_task ( @{ $jobs->{SPAWN_TASK} } ) {

                            # Check if the SPAWN Task exists
                            if ( -e $spawn_task ) {
                                $VTMBTool->info("Spawn Task was found: $spawn_task");
                            }
                            else {
                                $VTMBTool->info("Spawn Task was Not found: $spawn_task");
                            }
                            next
                              if ( $jobs->{STATUS} eq "NOT_GATING" && !-e $spawn_task );

                            # Get Task Information
                            my (
                                @spawn_task_name,       $spawn_task_logs,
                                @spawn_task_dependency, @temp_log
                            );
                            $spawn_task_logs = "";
                            open( SPAWNED_TASK, "$spawn_task" )
                              || die "Task file does not exist:$spawn_task\n";
                            while (<SPAWNED_TASK>) {
                                if (/^\s*task\s*(\w+.*)\s*/i) {
                                    push @spawn_task_name, $1;
                                }

                                if (/nbjob\s*run\s*--log-file\s*(\/\w+.*)\s/) {
                                    @temp_log = split( / /, $1 );
                                    chomp( $temp_log[0] );
                                    $temp_log[0] =~ s/\s*//g;
                                    $spawn_task_logs .=
                                      ( $spawn_task_logs eq "" )
                                      ? "$temp_log[0]"
                                      : " $temp_log[0]";
                                }
                            }
                            close(SPAWNED_TASK);
                            my $gating = ( $jobs->{STATUS} eq "NOT_GATING" ) ? 0 : 1;

                            # Handle Attributes about SPAWN TASK
                            my $spawn_auto_req;
                            if ( defined $jobs->{SPAWN_AUTO_REQ} ) {
                                $spawn_auto_req = $jobs->{SPAWN_AUTO_REQ};
                            }

                            # Create Job Object
                            $VTMBJob = new VTMBJob(
                                DUT       => $jobs->{DUT},
                                NAME      => basename( $jobs->{SPAWN_TASK}->[$index] ),
                                TASK_NAME => $spawn_task_name[0],
                                TASK_FILE => $jobs->{SPAWN_TASK}->[$index],
                                TASK_PATH => "/"
                                  . $VTMBObj->get('TASK_PREFIX')
                                  . "/$spawn_task_name[0]",
                                LOG_FILE    => $spawn_task_logs,
                                DEPENDENCY  => $jobs->{NAME},
                                DESC        => $jobs->{SPAWN_DESC}->[$index],
                                DEP_SUCCESS => 1,
                                WORKAREA    => $VTMBObj->get('MODEL')
                                  . "/GATEKEEPER/NBFeederTaskJobs",
                                MODEL            => $VTMBObj->get('MODEL'),
                                GATING           => $gating,
                                NBCLASS          => $jobs->{NBCLASS},
                                NBPOOL           => $jobs->{NBPOOL},
                                NBQSLOT          => $jobs->{NBQSLOT},
                                JOB_TYPE         => 'SPAWN',
                                SPAWN_AUTO_REQ   => $spawn_auto_req,
                                DISABLE_NB_CHECK => $disable_nb_check,
                              )
                              or die
"Error Initializing VTMBJob Object. Report this bug to GK Owner\n";

          # To Support Spawn Task within a Nested Task, we must re-create the parent task.

                         # Old Code
                         # Launch the Spawn Task
                         #$VTMBJob->submit_tasks($VTMBTool,$nbfeeder_ward,$nbfeeder_conf);

                            # Add the Job to the Global List
                            push @VTMBJobs, $VTMBJob;
                            $jobs_running++;
                            $index++;
                        }

          # To Support Spawn Task within a Nested Task, we must re-create the parent task.
                        if ( $index > 0
                          )    # If we have reference a spawned task and create an object.
                        {

                            # Reuse existing code to create and launch a nested task
                            @VTMBJobs = &CreateNestedTask();
                            $VTMBJobs[0]->submit_parent_task( $VTMBTool, $nbfeeder_ward,
                                $nbfeeder_conf, \@VTMBJobs );
                        }
                    }
                }

                elsif ( !( defined $jobs->{STATUS} )
                    && ( defined $jobs_completed{ $jobs->{TASK_NAME} } ) )
                {

                    # Detect retries
                    delete( $jobs_completed{ $jobs->{TASK_NAME} } );
                    $jobs_running++;
                    $VTMBTool->debug(
"Increasing jobs running to ${jobs_running} because $jobs->{TASK_PATH} is no longer completed."
                    );

                }

            }
            else {
                 if ($GkEventType eq "TURNIN" || $GkEventType  eq "RELEASE"){
                  foreach $jobs (@VTMBJobs) {
                    my $message;
                    my $mail_list;
                    if ( (( $jobs->{FAILING} ne "" ) && ( $jobs->{FAILING} > 0 ) && ( $jobs->{GATING} )&& ( defined $jobs->{SEND_MAIL}
                      ))||(($jobs->{STATUS} =~ m/NOT_GATING/ ) && ($jobs->{FAILING} > 0 ) &&($jobs->{FAILING} ne "" ) && ( defined $jobs->{SEND_MAIL} )) ) {
                      my $task_name = $jobs->{NAME};
                      next if ($notify_build_mon{$task_name}{seen} == 1);
                      $notify_build_mon{$task_name}{email} = $jobs->{SEND_MAIL};
                      chomp ($jobs->{DUT});
                      my $message = "Project: $ENV{PROJECT}\n";
                      $message .= "Pipeline: $ENV{GK_CLUSTER}\n";
                      $message .= "You are listed as the Build Monitor for the dut: ".
                          "$jobs->{DUT}.\n\n";
                      if ($GkEventType eq "TURNIN") {
                        $message .= "The job ".$jobs->{NAME}." failed during Turnin ".
                          "Stage for TurninID: $ENV{GK_TURNIN_ID}. \n\n";
                      } elsif ($GkEventType eq "RELEASE") {
                        $message .= "The job ".$jobs->{NAME}." failed during Release.\n\n";
                      }
                      $message .= "Path to Failure log: \n";
                      if ($jobs->{NAME}=~/regression/) {
                        $message .= "$ENV{MODEL}/GATEKEEPER/regress/\n"

                      } elsif ($jobs->{NAME}=~/FACT/) {
                         $message .= "$ENV{MODEL}/GATEKEEPER/factrun/\n"
                      } else {
                        $message .= "$ENV{MODEL}/GATEKEEPER/NBLOG:$task_name\n"
                      }
                      $VTMBTool->info("Sending mail for failure of $jobs->{NAME} to $notify_build_mon{$task_name}{email}");
                      $VTMBJobs[0]->notify_build_monitors( $notify_build_mon{$task_name}{email}, $ENV{GK_USER}, $message,$task_name );
            		      $notify_build_mon{$task_name}{seen} = 1;
                    }
                  }
                }
#    This was commented out because the code contained a BUG, remove ASAP.
#            # There is a class of jobs that are to run only when the Parent Task is completed. We will launch them here.
#            $jobs->task_status($VTMBTool,$nbfeeder_ward,$nbfeeder_conf);
#            if(($jobs->{NB_STATUS} =~ /Completed/) && ($launch_post == 0) && (defined $VTMBJobsPost[0]))
#             {
#               # Undef Status of Parent Task
#               $jobs->set('STATUS', undef);

                #               # Check to see if any Post Jobs Exist
                #               # If so, append to Job Hash
                #               foreach $jobs_post (@VTMBJobsPost)
                #                {
                #                  # Append Post Cmd Jobs to Jobs Hash
                #                  # Increment the number of running jobs.
                #                  push @VTMBJobs, $jobs_post;
                #                  $jobs_running++;
                #                  $launch_post++;
                #                }

#               # Create New Parent Task for addditional Jobs and Submit to FEEDER.
#               $VTMBTool->info("Submitting Post Jobs");
#               @VTMBJobs  = &CreateNestedTask();
#               $VTMBJobs[0]->submit_parent_task($VTMBTool,$nbfeeder_ward,$nbfeeder_conf,\@VTMBJobs);
#             }
            }
        }

# Detected when the number of running jobs has gone to zero, now Post_cmd jobs can be submitted.
# These jobs are to run only when the Parent Task is completed. .
        if ( $jobs_running == 0 ) {
            if ( ( $launch_post == 0 ) && ( defined $VTMBJobsPost[0] ) ) {
                $VTMBTool->info("There are unsubmitted Post Jobs");

                # Undef Status of Parent Task
                $VTMBJobs[0]->set( 'STATUS', undef );

                # Check to see if any Post Jobs Exist
                # If so, append to Job Hash
                foreach $jobs_post (@VTMBJobsPost) {

                    # Append Post Cmd Jobs to Jobs Hash
                    # Increment the number of running jobs.
                    push @VTMBJobs, $jobs_post;
                    $jobs_running++;
                    $launch_post++;
                }

                # Create New Parent Task for addditional Jobs and Submit to FEEDER.
                $VTMBTool->info("Submitting Post Jobs");
                @VTMBJobs = &CreateNestedTask();
                $VTMBJobs[0]
                  ->submit_parent_task( $VTMBTool, $nbfeeder_ward, $nbfeeder_conf,
                    \@VTMBJobs );
            }
            else {
                $VTMBTool->info(
                    "There are no more running jobs, process will be ending soon.");
            }
        }

    }

    # Blank Line
    $VTMBTool->log("");

    # Display the status of each job
    $VTMBTool->write_report( \@VTMBJobs, $job_report );
    $VTMBTool->info(
        "$ENV{GK_EVENTTYPE} on $ENV{GK_STEP} $ENV{GK_CLUSTER} has completed.");

    # Job is complete, lets write the final output status.
    &final_status();
    &create_dut_report();
    #Run hook at the end of build script
    if ( defined $Models{post_complete_script} && (!$PreBuildRegress) ) {
        my $script = $Models{post_complete_script};
        if ( -f $script ) {
            my $log = $VTMBObj->get('WORKAREA') . "/post_complete_script.log";
            if ( -e $log ) {

                # Figure out unique name
                my $num = 1;
                ++$num while ( -e "${log}.${num}" );

                # Update property to unique filename
                $log = "${log}.${num}";
            }

            $VTMBTool->info("Running post task complete script: ${script}");
            $VTMBTool->run("${script} 1> ${log}");
        }
    }

    $VTMBTool->log("");
    $VTMBTool->log("");

    # Cleaning Jobs from NBFeeder
    &delete_feeder_task("NONE");

    $VTMBTool->check_errors();
}

#-------------------------------------------------------------------------------
# signal_handler()
#   Process Interrupts
#-------------------------------------------------------------------------------
sub signal_handler {
    my $signame = shift;
    my ( $jobs, $response );

    # Display status and set up indentation
    $VTMBTool->indent_msg(0);
    $VTMBTool->indent_msg(2);

    # Process Interrupt Signals
    if ( $signame eq "USR1" ) {

        # This interrupt means always exit with 0.
        $VTMBTool->info("$GkEventType Interrupted: SIG{$signame}\n");

        # Clear all existing errors and suppress errors.
        $VTMBTool->clear_errors();
        $VTMBTool->set( 'SUPPRESS_ERRORS', 1 );
    }
    elsif ( $signame eq "ALRM" ) {
        if ( $GkEventType ne "RELEASE" ) {
            $VTMBTool->error(
"$GkEventType Interrupted: SIG{$signame}. Job ran longer than $Models{timeout}{$ENV{'GK_CLUSTER'}} hours\n"
            );
        }
        else {

# For Release have to support the case of a RELEASE hits the ALRM but jobs meet threshold such as being NOT_GATING or %Passes is acceptable.
# Get the Status of Any Job which has not completed.
            if ($jobs_launched) {

                # Get the Status of Any Job which has not completed.
                foreach $jobs (@VTMBJobs) {
                    if ( !defined $jobs->{PARENT_TASK} ) {
                        if ( !defined $jobs->{STATUS} ) {

                            # Check Status of outstanding Task
                            $jobs->task_status( $VTMBTool, $nbfeeder_ward,
                                $nbfeeder_conf );

                            # Set STATUS to NB_STATUS
                            $jobs->{STATUS} = $jobs->{NB_STATUS};

                            # Determine Task Status
                            $jobs->check_task_job_status($VTMBTool);
                        }
                    }
                }
            }
        }
    }
    elsif ( $signame eq "URG" ) {
        $VTMBTool->error(
"$GkEventType Interrupted, rejected from GK pipeline because EARLY Kill setting for build jobs reached.\n"
        );
    }
    elsif ( $signame eq "XCPU" ) {
        $VTMBTool->error(
"$GkEventType Interrupted, rejected from GK pipeline because EARLY Kill setting for regressions reached.\n"
        );
    }
    elsif ( $signame eq "ILL" ) {
        $VTMBTool->error(
"$GkEventType Interrupted, NBFeeder didn't accept task. Contact GK owner to restart\n"
        );
    }
    else {
        $VTMBTool->error("$GkEventType Interrupted: SIG{$signame}\n");
    }

    # Write the Final Report
    $VTMBTool->write_report( \@VTMBJobs, $job_report );

    # Dump the current status and remove jobs from feeder if any have been launched.
    if ($jobs_launched) {
        &final_status();
        &delete_feeder_task($signame);
    }

    # Terminate on errors
    $VTMBTool->check_errors();

    # Exit the Program
    $VTMBTool->terminate();    # Destory objects and exit
}

#-------------------------------------------------------------------------------
# Collect_Stats()
#   Enabled data collection on areas which have completed.
#-------------------------------------------------------------------------------
sub Collect_Stats {
    my $jobs;
    foreach $jobs (@VTMBJobs) {
        $jobs->set( 'STATUS',        "PASSED" );
        $jobs->set( 'NB_START_TIME', "01/01/2009 12:12:12" );
        if ( defined $jobs->{REGRESS_COUNT} ) {
            my $rpt = $jobs->{RPT_FILE};
            if ( $rpt =~ /\list\.\d+/ ) {
                $rpt =~ s/list\.\d+/list/;
                $jobs->set( 'RPT_FILE', $rpt );
            }
        }
    }

    &delete_feeder_task("NONE");
}

#-------------------------------------------------------------------------------
# delete_feeder_task()
#   At conclusion of job, delete all tasks from NBFeeder
#-------------------------------------------------------------------------------
sub delete_feeder_task {
    my $signal = shift(@_);

    my ( $cmd, @cmd_results );

    # Data Dumper
    my $vtmb_dump =
      $VTMBObj->get('MODEL') . "/GATEKEEPER" . "/vtmbjob.$ENV{'GK_EVENTTYPE'}.pl";
    open( FD, ">$vtmb_dump" );
    my $VTMBJobs = \@VTMBJobs;
    local $Data::Dumper::Purity = 1;
    print FD Data::Dumper->Dump( [$VTMBJobs], ["VTMBJobs"] );
    close FD;
    my @turnin_ids = split( / /, $ENV{GK_TURNIN_IDS} );

    foreach my $turnin_id (@turnin_ids) {

        my $dest_path = "$Models{turnin_task_data_upload_path}/turnin_$turnin_id";
        if ( !-e $dest_path ) {
            my $dir_cmd = "mkdir $dest_path";
            $VTMBTool->info("Creating directory using: $dir_cmd");
            $VTMBTool->run($dir_cmd);
        }
        my $copy_cmd = "cp -rpf $vtmb_dump $dest_path";
        my $filename = basename $vtmb_dump;
        $VTMBTool->info("Uploading $filename to $dest_path");
        if ( $VTMBTool->run($copy_cmd) == 0 ) {
            $VTMBTool->info("Successfully uploaded $vtmb_dump to $dest_path");
        }
        else {
            $VTMBTool->info("Error in uploading $vtmb_dump to $dest_path");
        }
    }

    # Disable Timeout
    alarm 0;

    # Collect Job Stats and dump for HSD Rollup if this site is enabled.
    if ( defined $Models{stats}{ $ENV{'SITE'} } ) {
        &generate_gk_stats( $Models{stats}{ $ENV{'SITE'} } );
    }

    # Generate Regression Perf Data if enabled
    # This can only be done in a BK Repo for now, fix for Git later.
    if (   ( defined $Models{hertz_data_disk} )
        && ( $GkConfig{version_control_lib} eq "BK" ) )
    {
        &generate_regression_perf_data( \@VTMBJobs );
    }

    # Start the process of cleaning up tasks from the Feeders.
    if ( $signal eq "NONE" ) {
        $VTMBTool->info(
"Removing $ENV{'GK_EVENTTYPE'} because $VTMBJobs[0]->{TASK_NAME} has completed "
        );

        # With a Nested Task, deleting the parent takes casre of the subtasks.
        if ( defined $VTMBJobs[0]->{TIME_2_LIVE} ) {
            $VTMBTool->info(
                "Time 2 Live Directive is Defined:  $VTMBJobs[0]->{TIME_2_LIVE}");
            $VTMBTool->info("Default Removal of Task file from NBFeeder is disabled");
        }
        else {
            if (   ( defined $VTMBJobs[0]->{FEEDER_TARGET} )
                && ( defined $VTMBJobs[0]->{TASK_ID} ) )
            {

                if (
                    $VTMBTool->run(
"/nfs/site/gen/adm/netbatch/nbfeeder/install/$ENV{'NBFEEDER_VERSION'}/bin/nbtask delete --block --timeout 600 --target $VTMBJobs[0]->{FEEDER_TARGET} $VTMBJobs[0]->{TASK_ID}"
                    ) == 0
                  )
                {
                    $VTMBTool->log(
                        "Deleted Task:$VTMBJobs[0]->{TASK_NAME}:$VTMBJobs[0]->{TASK_ID}");
                }
                else {
                    $VTMBTool->info("Could'nt Deleted Task:$VTMBJobs[0]->{TASK_NAME} ");
                }
            }
        }
    }
    else {
        $VTMBTool->info(
"Interrupt Signal SIG{$signal} received for $ENV{'GK_EVENTTYPE'} for $VTMBJobs[0]->{TASK_NAME} while it was $VTMBJobs[0]->{NB_STATUS}"
        );
        if (   ( defined $VTMBJobs[0]->{FEEDER_TARGET} )
            && ( defined $VTMBJobs[0]->{TASK_ID} ) )
        {
            $VTMBTool->info(
"Stopping $VTMBJobs[0]->{TASK_NAME} while it was $VTMBJobs[0]->{NB_STATUS}"
            );
            if (
                $VTMBTool->run(
"/nfs/site/gen/adm/netbatch/nbfeeder/install/$ENV{'NBFEEDER_VERSION'}/bin/nbtask stop --block --timeout 300 --target $VTMBJobs[0]->{FEEDER_TARGET} $VTMBJobs[0]->{TASK_ID}"
                ) == 0
              )
            {
                $VTMBTool->log(
                    "Stopped Task:$VTMBJobs[0]->{TASK_NAME}:$VTMBJobs[0]->{TASK_ID}");
            }
            else {
                $VTMBTool->info("Could'nt Stop Task:$VTMBJobs[0]->{TASK_NAME} ");
            }

 # If Time to live is set, do not remove from Feeder, directive will tell the feeder when.
            if ( defined $VTMBJobs[0]->{TIME_2_LIVE} ) {
                $VTMBTool->info(
                    "Time 2 Live Directive is Defined:  $VTMBJobs[0]->{TIME_2_LIVE}");
                $VTMBTool->info("Default Removal of Task file from NBFeeder is disabled");
            }
            else {

# If Time to Live Directive is set, disable the Task removal, NBFeeder will take care of it.
                sleep 60;
                $VTMBTool->info("Deleting $VTMBJobs[0]->{TASK_NAME}");
                if (
                    $VTMBTool->run(
"/nfs/site/gen/adm/netbatch/nbfeeder/install/$ENV{'NBFEEDER_VERSION'}/bin/nbtask delete --block --timeout 300 --target $VTMBJobs[0]->{FEEDER_TARGET} $VTMBJobs[0]->{TASK_ID}"
                    ) == 0
                  )
                {
                    $VTMBTool->log(
                        "Deleted Task:$VTMBJobs[0]->{TASK_NAME}:$VTMBJobs[0]->{TASK_ID}");
                }
                else {
                    $VTMBTool->info("Could'nt Deleted Task:$VTMBJobs[0]->{TASK_NAME} ");
                }

                sleep 60;
                $VTMBTool->info("Force Deleting $VTMBJobs[0]->{TASK_NAME}");
                if (
                    $VTMBTool->run(
"/nfs/site/gen/adm/netbatch/nbfeeder/install/$ENV{'NBFEEDER_VERSION'}/bin/nbtask delete --block --timeout 300 --force --target $VTMBJobs[0]->{FEEDER_TARGET} $VTMBJobs[0]->{TASK_ID}"
                    ) == 0
                  )
                {
                    $VTMBTool->log(
"Force Deleted Task:$VTMBJobs[0]->{TASK_NAME}:$VTMBJobs[0]->{TASK_ID}"
                    );
                }
                else {
                    $VTMBTool->info(
                        "Could'nt Force Deleted Task:$VTMBJobs[0]->{TASK_NAME} ");
                }
            }
        }
    }

    # Check if the Task is still present in the Feeder.

    # Temporary Hack to enable commands to run after turnins complete.
    if ( defined $Models{post_turnin_cmds} && ( !$print_commands ) ) {
        $VTMBTool->info("Post Turnin Commands Defined. ");

        # Loop thru the commands and run them.
        foreach my $cmd_idx ( @{ $Models{post_turnin_cmds} } ) {
            $cmd = $cmd_idx;
            $VTMBTool->info("Running command : $cmd");
            if ( $VTMBTool->run( $cmd, \@cmd_results ) == 0 ) {
                $VTMBTool->info(" Post Turnin CMD Invocation Passed for : $cmd");
            }
            else {
                $VTMBTool->warning(" Post Turnin CMD Invocation failed for : $cmd");

                foreach my $cmd_result_idx (@cmd_results) {
                    $VTMBTool->warning("Failure : $cmd_result_idx  ");
                }
            }
        }
    }

}

#-------------------------------------------------------------------------------
# final_status()
#   Write to STDOUT and create GK report for final status at end of job.
#-------------------------------------------------------------------------------

sub final_status {

    # Display the status of each job
    $VTMBTool->write_report( \@VTMBJobs, $job_report );
    $VTMBTool->set( 'QUIET', 0 );

    my $max_width = length(
        ( sort { length( $a->{DESC} ) <=> length( $b->{DESC} ) } @VTMBJobs )[-1]{DESC} );
    my $space = $max_width + 3;

    my %nbflow_status = ();

    foreach my $job (@VTMBJobs) {
        if ( $job->{NBFLOW} ) {
            $nbflow_status{ $job->{NAME} }{tasks}  = $job->{NBFLOW_COUNT};
            $nbflow_status{ $job->{NAME} }{passed} = 0;
            $nbflow_status{ $job->{NAME} }{failed} = 0;
        }
    }

    foreach my $job (@VTMBJobs) {
        if ( !defined $job->{PARENT_TASK} ) {

            # If not, initialize NB_STATUS to STATUS.
            #         initialize  PASSING = FAILING = 0;
            if ( !defined $job->{STATUS} ) {
                $job->{STATUS} = $job->{NB_STATUS};

                if (   ( defined $job->{REGRESS_COUNT} )
                    || ( defined $job->{NBFLOW} ) )
                {
                    if (   ( defined $job->{PASSING} )
                        && ( $job->{PASSING} !~ /\d+/ ) )
                    {
                        $job->{PASSING} = 0;
                    }

                    if (   ( defined $job->{FAILING} )
                        && ( $job->{FAILING} !~ /\d+/ ) )
                    {
                        $job->{FAILING} = 0;
                    }
                }
            }

            if ( $job->{NBFLOW_NESTED} ) {
                if ( $job->{STATUS} =~ m/PASSED/ ) {
                    $nbflow_status{ $job->{NBFLOW_NESTED} }{passed}++;
                }
                elsif (( $job->{STATUS} =~ m/FAILED|TIMEOUT/ )
                    || ( $job->{STATUS} =~ m/Skipped_GATING/ ) )
                {
                    $nbflow_status{ $job->{NBFLOW_NESTED} }{failed}++;
                }
            }
        }
    }

    foreach my $job (@VTMBJobs) {
        if ( !defined $job->{PARENT_TASK} ) {

            # Setup Output Message
            my $msg = sprintf( '%-*s%s', $space, "$job->{DESC}:", "$job->{STATUS}" );
            if (   ( $job->{NBFLOW} )
                || ( $job->{STATUS} =~ m/NOT_GATING/ )
                || ( $job->{REGRESS_COUNT} ) )
            {
                $msg .= "(Passed=$job->{PASSING},Failed=$job->{FAILING})";
            }

            if ( $job->{STATUS} =~ m/FAILED|TIMEOUT/ ) {
                $msg .= $job->regress_output_summary($VTMBTool)
                  if ( $job->{REGRESS_COUNT} );
                my $msg2 = $job->{LOG_FILE};
                $msg = $msg . "\t\t View: $msg2" if ( !$job->{REGRESS_COUNT} );
            }

            # Print Output status for the job
            if (   ( $job->{STATUS} =~ m/PASSED/ )
                || ( $job->{STATUS} =~ m/NOT_GATING/ ) )
            {
                if ( !$job->{NBFLOW_NESTED} ) {
                    $VTMBTool->info($msg);
                }
            }
            elsif ( $job->{STATUS} =~ m/FAILED|TIMEOUT/ ) {
                $msg =~
                  s/(?<=\Q$job->{DESC}:\E)\s+(?=\Q$job->{STATUS}\E)/"-" x length($&)/eg;

                $VTMBTool->error($msg);
            }
            elsif ( $job->{STATUS} =~ m/Skipped_GATING/ ) {
                if ( !$job->{NBFLOW_NESTED} ) {
                    $VTMBTool->error($msg);
                }
            }
            else {
                $VTMBTool->info($msg);
            }
        }
    }

    $VTMBTool->set( 'QUIET', 1 ) if !$ENV{'DISABLE_QUIET_MODE'};
}


sub create_dut_report {
    my %dut_report;
    my $gk_dir = $VTMBObj->get('MODEL') . "/GATEKEEPER/";
    my $csv = $gk_dir . "gk_report.csv";
    open (IN, "<$csv") || die "unable to open file $csv for reading\n";
    my @lines = <IN>;
    close IN;
    shift @lines;
    foreach my $line (@lines) {
        my @report = split /,/, $line;
        my $dut = $report[0];
        my $status = $report[2];
        $status =~ s/^\s+|\s+$//g;
        $status = "FAILED" if $status eq "Skipped_GATING";
        $status = "PASSED" if $status eq "Skipped_NOT_GATING";
        my $end_time = $report[4];
        if ( (defined $dut_report{$dut}) ) {
            next if ( $dut_report{$dut}{status} eq "FAILED" );
            $dut_report{$dut}{status} = $status;

        } else {
            $dut_report{$dut}{status} = $status;
        }
        #$dut_report{$dut}{time} = $end_time;

    }
    chomp( my $commit_id = `/usr/intel/bin/git rev-parse HEAD`);
    #dump the data to dut-commit id report with status,#TODO timestamp
    foreach my $dut ( keys %dut_report) {
        my $dut_fname = $dut."-".$commit_id;
        open(DUT_CSV, "> $gk_dir.$dut_fname");
        print DUT_CSV "$dut_report{$dut}{status}";#, $dut_report{$dut}{time}";
    }

}

sub update_ibi_merge {
    return unless ( $ENV{GK_EVENTTYPE} eq "turnin" || $ENV{GK_EVENTTYPE} eq "filter" );
    $VTMBTool->info( "Updating IBImerge at " . scalar(localtime) . "\n" );
    my $timeout = 60 * 5;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $timeout;
        system("$ProgramDir/Merge2IBI.pl 2>&1");
        alarm 0;
    };
    $VTMBTool->info("timeout during update ibi merge\n") if ( $@ =~ /timeout/ );
}

sub report_to_ibi {
    return if ( $ENV{'GK_EVENTTYPE'} eq "mock" );
    return unless ( defined $ENV{'GK_TURNIN_ID'} || defined $ENV{'GK_RELEASE_ID'} );

    # Put ibi Code in QUIET MODE so it does not write to STDOUT.
    $VTMBTool->set( 'QUIET', 1 ) if !$ENV{'DISABLE_QUIET_MODE'};

    # 5 minute timeout on tracking indicators
    my $warn = $SIG{__WARN__};
    $SIG{__WARN__} = sub { };
    local $SIG{ALRM} = sub { die "timeout"; };
    $@ = "";

    my $alarm = 60 * 5;
    alarm $alarm;

    my $ibi_table = 'GK_TASKS';

    eval {
        update_ibi_merge();
        foreach my $task (@VTMBJobs) {
            if ( !defined $task->{PARENT_TASK} ) {
                next
                  if ( $task->{DESC} =~ /NBFEEDER ENV DUMP/
                    || $task->{DESC} =~ /Remove nbfeeder logs/
                    || !defined $task->{CMDS}
                    || $task->{STATUS} =~ /Skipped_GATING/
                    || $task->{NB_START_TIME} eq ''
                    || $task->{NB_END_TIME}   eq '' );

                my %ibi_TASK_Rec;

                $ibi_TASK_Rec{gk_attempts} = $ENV{'GK_ATTEMPTS'}
                  if defined $ENV{GK_ATTEMPTS};
                $ibi_TASK_Rec{turninid} = $ENV{'GK_TURNIN_ID'}
                  if defined $ENV{'GK_TURNIN_ID'};
                $ibi_TASK_Rec{gk_release_id} = $ENV{'GK_RELEASE_ID'}
                  if defined $ENV{'GK_RELEASE_ID'};
                $ibi_TASK_Rec{gk_event} = $ENV{'GK_EVENTTYPE'}
                  if defined $ENV{'GK_EVENTTYPE'};
                $ibi_TASK_Rec{gk_bundle_id} = $ENV{'GK_BUNDLE_ID'}
                  if defined $ENV{'GK_BUNDLE_ID'};
                $ibi_TASK_Rec{successful} = $task->{STATUS} =~ /FAILED/ ? 0 : 1;
                $ibi_TASK_Rec{submittime} = $task->{NB_SUBMITTED_TIME};
                $ibi_TASK_Rec{starttime}  = $task->{NB_START_TIME};
                $ibi_TASK_Rec{finishtime} = $task->{NB_END_TIME};
                $ibi_TASK_Rec{dut}        = $task->{DUT} if defined $task->{DUT};
                $ibi_TASK_Rec{stage_name} = $task->{NAME};
                $ibi_TASK_Rec{stage_type} =
                  defined $task->{REGRESS_COUNT}
                  ? "regress"
                  : ( $task->{CMDS} =~ /simbuild/ ? "build" : "other" );
                $ibi_TASK_Rec{cluster}  = $ENV{'GK_CLUSTER'};
                $ibi_TASK_Rec{stepping} = $ENV{'GK_STEP'};
                my $cmd = &assemble_ibi_cmd( \%ibi_TASK_Rec, $ibi_table );
                $VTMBTool->info("Running: $cmd");
                $VTMBTool->info("failed to execute ibiLog.") if system($cmd);
            }
        }
    };
    alarm 0;
    if ( $@ =~ /timeout/ ) {
        $VTMBTool->info(
            "TIMEOUT while updating indicators (exitted after $alarm seconds)");
        $VTMBJobs[0]->job_status_email( "yaelz", $ENV{'USER'}, "",
            "TIMEOUT while updating indicators for TI: $ENV{'GK_TURNIN_ID'}", "" );
    }
    $SIG{__WARN__} = $warn;

}

###########################
# Assemble and return an ibiLog update command
# @params: task - the task to update
#          fh (optional) - file handler to record the task in the log file
###########################
sub assemble_ibi_cmd {
    my $ibi_TASKJOB_Rec = shift @_;
    my $table           = shift @_;

    my $ibiLoger = "/usr/intel/bin/ibilogger";

    my $ibiCmd = "project=$ENV{PROJECT},";
    foreach ( keys %$ibi_TASKJOB_Rec ) {
        $ibiCmd .= "$_=$ibi_TASKJOB_Rec->{$_},";
    }

    # remove the last comma
    $ibiCmd =~ s/,$//;

    $ibiCmd =
"$ibiLoger log --ta ibi-prod-collection.iil.intel.com --topic $table --data \"$ibiCmd\" ";
    return $ibiCmd;
}

#-------------------------------------------------------------------------------
# generate_gk_stats()
#   At conclusion of job, generate stats fo this run.
#-------------------------------------------------------------------------------
sub generate_gk_stats {
    my $stats_location = shift(@_);
    my $jobs;

    # Collect Job Stats and dump for HSD Rollup.
    # Create CSV file for HSD Rollup
    my $csv_file = $VTMBObj->get('MODEL') . "/GATEKEEPER/gk_stats_report.csv";
    my ( $title, $line, $host, $stage, $cputime, $walltime );
    my ($hsdid);
    my ( @bitkeeper_ops, $bk );

# Some GK Variables may be undefined in Mock turnin. For purposes of this script. Define them since its about to exit.
    if ( !defined $ENV{'GK_TURNIN_ID'} ) {
        $ENV{'GK_TURNIN_ID'} = "";
    }
    if ( !defined $ENV{'GK_RELEASE_ID'} ) {
        $ENV{'GK_RELEASE_ID'} = "";
    }
    if ( !defined $ENV{'GK_ATTEMPTS'} ) {
        $ENV{'GK_ATTEMPTS'} = "";
    }
    if ( !defined $ENV{'GK_BUNDLE_SIZE'} ) {
        $ENV{'GK_BUNDLE_SIZE'} = "";
    }
    if ( !defined $ENV{'GK_USER'} ) {
        $ENV{'GK_USER'} = "";
    }

    # Create Top row for CSV file
    open( HSD_CSV, ">$csv_file" );
    $title =
'"flow","event","status","user","host","hsdid","attempt","cluster","stepping","model","dut","stage","sub_stage","bundle_cnt","tool_stage","tool_sub_stage","start_date","cputime","walltime"';
    print HSD_CSV "$title\n";

    # Grab HSD ID
    if ( ( $ENV{'GK_EVENTTYPE'} eq "filter" ) || ( $ENV{'GK_EVENTTYPE'} eq "turnin" ) ) {
        $hsdid = $ENV{'GK_TURNIN_ID'};
    }
    elsif (( $ENV{'GK_EVENTTYPE'} eq "release" )
        || ( $ENV{'GK_EVENTTYPE'} eq "post-release" ) )
    {
        $hsdid = $ENV{'GK_RELEASE_ID'};
    }
    else {
        $hsdid = "";
    }

    # If Turnin of Job, Grab time for Bit Keeper operations.
    my $merge_log = $VTMBObj->get('MODEL') . "/GATEKEEPER/merge.log";
    if (
        ( -e $merge_log )
        && (   ( $ENV{'GK_EVENTTYPE'} eq "filter" )
            || ( $ENV{'GK_EVENTTYPE'} eq "turnin" ) )
      )
    {
        @bitkeeper_ops = &get_bk_times($merge_log);
        foreach $bk (@bitkeeper_ops) {

            #Create the Line for Bitkeeeper Operations

            $line = "\"gatekeeper\",\"";    # Flow

            ##Event
            if ( $ENV{'GK_EVENTTYPE'} eq "filter" ) {
                $line .= "turnin\",\"";
            }
            else {
                $line .= "$ENV{'GK_EVENTTYPE'}\",\"";
            }

            $line .= "PASSED\",\"";                # Status
            $line .= "$ENV{'GK_USER'}\",\"";       # User
            $line .= "$ENV{'HOST'}\",\"";          # Host
            $line .= "$hsdid\",\"";                # HSD Id
            $line .= "$ENV{'GK_ATTEMPTS'}\",\"";
            $line .= "$ENV{'GK_CLUSTER'}\",\"";
            $line .= "$ENV{'GK_STEP'}\",\"";
            if (   ( $ENV{'GK_EVENTTYPE'} eq "release" )
                || ( $ENV{'GK_EVENTTYPE'} eq "post-release" ) )
            {
                $line .= basename( $VTMBObj->get('MODEL') ) . "\",\"";
            }
            else {
                $line .= "\",\"";
            }
            $line .= "\",\"";                      # No Dut for BK operation

            # Grab Stage, Substage, Start Date, Wallclock
            my ( $stage, $substage, $start_date, $wallclock ) = split( /,/, $bk );
            $line .= "$stage\",\"";                    # Stage
            $line .= "$substage\",\"";                 # Sub Stage
            $line .= "$ENV{'GK_BUNDLE_SIZE'}\",\"";    # Bundle Count
            $line .= "\",\"";                          # No Tool Stage
            $line .= "\",\"";                          # No Tool Sub Stage
                 # Fix Start Date to be consistent with other rows.
            $start_date = &fix_bk_start_date($start_date);
            $line .= "$start_date\",\"";    # Start Date
            $line .= "\",\"";               # No CPU Time
            $line .= "$wallclock\"";        # Wall Clock
            print HSD_CSV "$line\n";
        }
    }

    # Loop thru the jobs and populate the record
    foreach $jobs (@VTMBJobs) {
        if ( defined $jobs->{STATUS} && !defined $jobs->{PARENT_TASK} ) {
            my $substage = $jobs->{DESC};
            $substage =~ s/^\s*$jobs->{DUT}\s*// if defined $jobs->{DUT};
            next
              if ( $jobs->{DESC} =~ /NBFEEDER ENV DUMP/
                || $jobs->{DESC} =~ /Remove nbfeeder logs/ );

            # print "$jobs->{DESC}\n";
            if (   defined $jobs->{GENERAL_JOB}
                || defined $jobs->{REGRESS_COUNT}
                || $jobs->{LOG_FILE} =~ /\s+/ )
            {
                $jobs->get_stats_from_feeder($VTMBTool);
            }
            else {
                $jobs->collect_build_job_stats($VTMBTool) if ( -e $jobs->{LOG_FILE} );
            }

            my @job_stats = split( /;/, $jobs->{JOB_RUN_STATS} )
              if ( defined $jobs->{JOB_RUN_STATS} );

            foreach my $stage_stats (@job_stats) {
                next if $stage_stats =~ /regress/;
                my ( $host, $stage, $sub_stage, $status, $start_time, $walltime,
                    $cputime ) = split( /,/, $stage_stats );

                # Create the Line for HSD Stats
                $line = "\"gatekeeper\",\"";
                if ( $ENV{'GK_EVENTTYPE'} eq "filter" ) {
                    $line .= "turnin\",\"";
                }
                else {
                    $line .= "$ENV{'GK_EVENTTYPE'}\",\"";
                }

                $line .= "$jobs->{STATUS}\",\"";
                $line .= "$ENV{'GK_USER'}\",\"";
                $line .= "$host\",\"";
                $line .= "$hsdid\",\"";                # HSD Id
                $line .= "$ENV{'GK_ATTEMPTS'}\",\"";
                $line .= "$ENV{'GK_CLUSTER'}\",\"";
                $line .= "$ENV{'GK_STEP'}\",\"";
                if (   ( $ENV{'GK_EVENTTYPE'} eq "release" )
                    || ( $ENV{'GK_EVENTTYPE'} eq "post-release" ) )
                {
                    $line .= basename( $VTMBObj->get('MODEL') ) . "\",\"";
                }
                else {
                    $line .= "\",\"";
                }
                $line .= $jobs->{DUT} . "\",\"";

                # This is the stage section.
                if (   ( $ENV{'GK_EVENTTYPE'} eq "filter" )
                    && ( !defined $jobs->{REGRESS_COUNT} ) )
                {
                    $line .= "filter build\",\"";
                }
                elsif (( $ENV{'GK_EVENTTYPE'} eq "filter" )
                    && ( defined $jobs->{REGRESS_COUNT} ) )
                {
                    $line .= "filter regress\",\"";
                }
                elsif (( $ENV{'GK_EVENTTYPE'} eq "post-release" )
                    && ( !defined $jobs->{REGRESS_COUNT} ) )
                {
                    $line .= "post build\",\"";
                }
                elsif (( $ENV{'GK_EVENTTYPE'} eq "post-release" )
                    && ( defined $jobs->{REGRESS_COUNT} ) )
                {
                    $line .= "post regress\",\"";
                }
                elsif (( $ENV{'GK_EVENTTYPE'} eq "mock" )
                    && ( !defined $jobs->{REGRESS_COUNT} ) )
                {
                    $line .= "mock build\",\"";
                }
                elsif (( $ENV{'GK_EVENTTYPE'} eq "mock" )
                    && ( defined $jobs->{REGRESS_COUNT} ) )
                {
                    $line .= "mock regress\",\"";
                }
                elsif (( $ENV{'GK_EVENTTYPE'} eq "turnin" )
                    && ( !defined $jobs->{REGRESS_COUNT} ) )
                {
                    $line .= "build\",\"";
                }
                elsif (( $ENV{'GK_EVENTTYPE'} eq "turnin" )
                    && ( defined $jobs->{REGRESS_COUNT} ) )
                {
                    $line .= "regress\",\"";
                }
                else {
                    $line .= "build\",\"";
                }
                $line .= "$substage\",\"";
                $line .= "$ENV{'GK_BUNDLE_SIZE'}\",\"";
                $line .= "$stage\",\"$sub_stage\",\"";
                $start_time =~ s/\n//;
                $line .= "$start_time\",\"";
                $line .= "$cputime\",\"";
                $walltime = &fix_build_walltime($walltime);
                $line .= "$walltime\"";
                print HSD_CSV "$line\n";
            }
        }

    }
    close(HSD_CSV);

    # Move the file to GK Stats Area
    my $stats_file = $stats_location . "/";
    my $copy       = 0;

# Create Stats file for Turnin. Check for ENV vars to distinguish actual GK run from developer testing.
    if (   ( $ENV{'GK_EVENTTYPE'} eq "filter" )
        && ( defined $ENV{'GK_TURNIN_ID'} )
        && ( defined $ENV{'GK_ATTEMPTS'} ) )
    {
        $stats_file .= "filter.$ENV{'GK_TURNIN_ID'}.$ENV{'GK_ATTEMPTS'}.csv";
        $copy = 1;
    }

# Create Stats file for Release. Check for ENV vars to distinguish actual GK run from developer testing.
    if (   ( $ENV{'GK_EVENTTYPE'} eq "turnin" )
        && ( defined $ENV{'GK_TURNIN_ID'} )
        && ( defined $ENV{'GK_ATTEMPTS'} ) )
    {
        $stats_file .= "turnin.$ENV{'GK_TURNIN_ID'}.$ENV{'GK_ATTEMPTS'}.csv";
        $copy = 1;
    }
    if ( ( $ENV{'GK_EVENTTYPE'} eq "release" ) && ( defined $ENV{'GK_RELEASE_ID'} ) ) {
        $stats_file .= "release.$ENV{'GK_RELEASE_ID'}.csv";
        $copy = 1;
    }
    if ( ( $ENV{'GK_EVENTTYPE'} eq "post-release" ) && ( defined $ENV{'GK_RELEASE_ID'} ) )
    {
        $stats_file .= "post.release.$ENV{'GK_RELEASE_ID'}.csv";
        $copy = 1;
    }

    # if(($ENV{'GK_EVENTTYPE'} eq "mock")&&(defined $ENV{'GK_HOST'}))
    #  {
    #    $stats_file .= "mock.$ENV{'GK_USER'}.$ENV{'MY_PID'}.$ENV{'GK_CLUSTER'}.csv";
    #   #$copy = 1;
    #  }

    if ( ( $copy == 1 ) && ( !defined $ENV{'GK_DEV'} ) ) {
        if ( $VTMBTool->run("cp $csv_file $stats_file") == 0 ) {
            $VTMBTool->run("chmod 770 $stats_file");
            $VTMBTool->log("Successfully copying stats file to $stats_file");
        }
        else {
            $VTMBTool->log("Was unsuccessful in copying stats file to $stats_file");
        }

    }
}

#-------------------------------------------------------------------------------
# fix_build_walltime()
#   Convert Build Job's Wall Time to consistent format of seconds.
#-------------------------------------------------------------------------------
sub fix_build_walltime {
    my $walltime = shift(@_);
    return $walltime unless $walltime =~ /:/;
    my ( $hours, $minutes, $seconds ) = split( /:/, $walltime );
    my $time_in_seconds = ( 3600 * $hours ) + ( 60 * $minutes ) + $seconds;

    return $time_in_seconds;

}

#-------------------------------------------------------------------------------
# fix_bk_start_date()
#   Convert Bitkeeper Start Date to a consistent format
#-------------------------------------------------------------------------------
sub fix_bk_start_date {
    my $start_date = shift(@_);
    $start_date =~ s/:/ /g;
    $start_date =~ s/\s+/ /g;
    my ( $day_week, $month, $day_of_month, $hours, $minute, $second, $year ) =
      split( / /, $start_date );
    my $temp;

    # Keep Day of Month as 2 digit field
    if ( $day_of_month < 10 ) {
        $day_of_month = "0$day_of_month";
    }

    $temp = ( $month + 1 ) . "/" . $day_of_month . "/" . $year;
    $temp .= " $hours:$minute:$second";
    return $temp;
}

#-------------------------------------------------------------------------------
# get_bk_times()
#   At conclusion of job, generate for the bitkeeper operations
#-------------------------------------------------------------------------------
sub get_bk_times {
    my $logfile = shift(@_);
    my ( $run, $time_1, $time_2 );
    my ( $time_job_end, $time_job_start );
    my ($time_elapsed);
    my ( @time_end, @time_start, @start_time_raw );
    my ($time_1_raw);
    my (@run_cmd);
    my ( $incomingRepo, $workRepo, $masterRepo );
    my ( @line, @returnMe );
    my ($substage);
    my $i;
    my ( $day_week, $month, $day_month, $hour, $minute, $second, $year );
    open( LOG, $logfile );

    $run = 0;
    while (<LOG>) {

        # Grab Bitkeeper Information
        if (/^incoming repo\s*=\s*/) {
            @line = split( /=/, $_ );
            chomp( $line[-1] );
            $line[-1] =~ s/\s*//g;
            $incomingRepo = $line[-1];
        }
        if (/^work repo\s*=\s*/) {
            @line = split( /=/, $_ );
            chomp( $line[-1] );
            $line[-1] =~ s/\s*//g;
            $workRepo = $line[-1];
        }
        if (/^master repo\s*=\s*/) {
            @line = split( /=/, $_ );
            chomp( $line[-1] );
            $line[-1] =~ s/\s*//g;
            $masterRepo = $line[-1];
        }

        if (/time:\s*(\w+)\s*(\w+)\s*(\d+)\s*(\d+):(\d+):(\d+)\s*(\d+)/) {
            $day_week  = $1;
            $month     = month_2_num($2);
            $day_month = $3;
            $hour      = $4;
            $minute    = $5;
            $second    = $6;
            $year      = $7;

            if ( $run == 0 ) {
                $time_1     = "$day_week,$month,$day_month,$hour,$minute,$second,$year";
                $time_1_raw = "$day_week $month $day_month $hour:$minute:$second $year";
            }
            else {
                $time_2 = "$day_week,$month,$day_month,$hour,$minute,$second,$year";
                $run    = 0;
                push @time_end, $time_2;
            }

        }
        if (/Run:/) {
            $run = 1;
            push @time_start,     $time_1;
            push @run_cmd,        $_;
            push @start_time_raw, $time_1_raw;
        }
    }
    close(LOG);

    for ( $i = 0 ; $i < @time_start ; $i++ ) {
        ( $day_week, $month, $day_month, $hour, $minute, $second, $year ) =
          split( /,/, $time_start[$i] );
        $time_job_start = timegm( $second, $minute, $hour, $day_month, $month, $year );

        ( $day_week, $month, $day_month, $hour, $minute, $second, $year ) =
          split( /,/, $time_end[$i] );
        $time_job_end = timegm( $second, $minute, $hour, $day_month, $month, $year );

        $time_elapsed = $time_job_end - $time_job_start;

        if ( ( $run_cmd[$i] =~ /$incomingRepo/ ) && ( $run_cmd[$i] =~ /clone/ ) ) {

            #print "Cloning Incoming\n";
            $substage = "clone";
        }
        elsif ( ( $run_cmd[$i] =~ /$masterRepo/ ) && ( $run_cmd[$i] =~ /pull/ ) ) {

            #print "Pulling Master\n";
            $substage = "pull.master_repo";
        }
        elsif ( ( $run_cmd[$i] =~ /incomingrepo/ ) && ( $run_cmd[$i] =~ /pull/ ) ) {

            #print "Pulling Incoming\n";
            $substage = "pull.incoming_repo";
        }
        elsif ( ( $run_cmd[$i] =~ /workrepo/ ) && ( $run_cmd[$i] =~ /pull/ ) ) {

            #print "Pulling WorkRepo\n";
            $substage = "pull.work_repo";
        }
        elsif ( $run_cmd[$i] =~ /get/ ) {

            #print "Getting Files\n";
            $substage = "get.files";
        }
        else {
            print "Unknown Bitkeeper Operation\n";
            $substage = "unknown.bk_op";
        }

        #
        push @returnMe, "bitkeeper,$substage,$start_time_raw[$i],$time_elapsed";
    }
    return @returnMe;
}

sub month_2_num {
    my $month        = shift;
    my %month_to_num = (
        "Jan" => 0,
        "Feb" => 1,
        "Mar" => 2,
        "Apr" => 3,
        "May" => 4,
        "Jun" => 5,
        "Jul" => 6,
        "Aug" => 7,
        "Sep" => 8,
        "Oct" => 9,
        "Nov" => 10,
        "Dec" => 11
    );
    return $month_to_num{$month};
}

#----------------------------------------------------------------------------------------
# CleanTargetDirectory()
# In Mockturnin we need to clean stuff in the target directory as a workaround
# to an elusive VCS bug related to incremental build
#----------------------------------------------------------------------------------------
sub CleanTargetDirectory {
    $VTMBTool->info("Cleaning target directory for mockturnin...");
    system("/bin/rm -rf target/*/sim/* >& /dev/null");
    system("/bin/rm -rf target/*/vcsobj/* >& /dev/null");
}

#-------------------------------------------------------------------------------
# determine_nb_configuration()
#   Determine the Correct NB Variable Settings and handle any Global Overrides.
#-------------------------------------------------------------------------------

sub determine_nb_configuration {
    my $build_cmd       = shift(@_);
    my $job_name        = shift(@_);
    my $event_type      = shift(@_);
    my $gk_mock_nbpool  = shift(@_);
    my $gk_mock_nbclass = shift(@_);
    my $gk_mock_nbqslot = shift(@_);
    my $env_nbpool      = shift(@_);
    my $env_nbclass     = shift(@_);
    my $env_nbqslot     = shift(@_);
    my ( $pool, $class, $qslot, $new_class );
    my ( $newpool, $newclass, $newqslot );

    # Set NBPool, Class, and Qslot
    $pool =
      find_nb_settings( $build_cmd->{NBPOOL}, $event_type, $gk_mock_nbpool, $env_nbpool,
        "NBPOOL" );
    $class =
      find_nb_settings( $build_cmd->{NBCLASS}, $event_type, $gk_mock_nbclass,
        $env_nbclass, "NBCLASS" );
    $qslot =
      find_nb_settings( $build_cmd->{NBQSLOT}, $event_type, $gk_mock_nbqslot,
        $env_nbqslot, "NBQSLOT" );

    # Determine if a NB Override is setup
    if ( defined $netbatch_override->{$pool}{$class}{$qslot} ) {

        # Look for Filter and see which jobs need to be override, GLOBAL is ALL.
        # Look for the job type like build or regress, then ALL.
        if (   ( defined $netbatch_override->{$pool}{$class}{$qslot}{'build'} )
            && ( !defined $build_cmd->{'LIST'} ) )
        {
            $VTMBTool->info(
"Netbatch Configuration has been overridden for BUILD Job $build_cmd->{NAME}"
            );
            $VTMBTool->info(
"  NBPOOL  old = $pool  :\t NBPOOL  new = $netbatch_override->{$pool}{$class}{$qslot}{'build'}{'NBPOOL'}"
            );
            $VTMBTool->info(
"  NBCLASS old = $class :\t NBCLASS new = $netbatch_override->{$pool}{$class}{$qslot}{'build'}{'NBCLASS'}"
            );
            $VTMBTool->info(
"  NBQSLOT old = $qslot :\t NBQSLOT new = $netbatch_override->{$pool}{$class}{$qslot}{'build'}{'NBQSLOT'}"
            );

            $newpool  = $netbatch_override->{$pool}{$class}{$qslot}{'build'}{'NBPOOL'};
            $newclass = $netbatch_override->{$pool}{$class}{$qslot}{'build'}{'NBCLASS'};
            $newqslot = $netbatch_override->{$pool}{$class}{$qslot}{'build'}{'NBQSLOT'};
            $pool     = $newpool;
            $class    = $newclass;
            $qslot    = $newqslot;
        }
        elsif (( defined $netbatch_override->{$pool}{$class}{$qslot}{'regress'} )
            && ( defined $build_cmd->{'LIST'} ) )
        {
            $VTMBTool->info(
"Netbatch Configuration has been overridden for REGRESS Job $build_cmd->{NAME}"
            );
            $VTMBTool->info(
"  NBPOOL  old = $pool  :\t NBPOOL  new = $netbatch_override->{$pool}{$class}{$qslot}{'regress'}{'NBPOOL'}"
            );
            $VTMBTool->info(
"  NBCLASS old = $class :\t NBCLASS new = $netbatch_override->{$pool}{$class}{$qslot}{'regress'}{'NBCLASS'}"
            );
            $VTMBTool->info(
"  NBQSLOT old = $qslot :\t NBQSLOT new = $netbatch_override->{$pool}{$class}{$qslot}{'regress'}{'NBQSLOT'}"
            );

            $newpool  = $netbatch_override->{$pool}{$class}{$qslot}{'regress'}{'NBPOOL'};
            $newclass = $netbatch_override->{$pool}{$class}{$qslot}{'regress'}{'NBCLASS'};
            $newqslot = $netbatch_override->{$pool}{$class}{$qslot}{'regress'}{'NBQSLOT'};
            $pool     = $newpool;
            $class    = $newclass;
            $qslot    = $newqslot;
        }
        elsif ( defined $netbatch_override->{$pool}{$class}{$qslot}{'FILTER'}
            && ( $netbatch_override->{$pool}{$class}{$qslot}{'FILTER'} eq "ALL" ) )
        {
            $VTMBTool->info(
                "Netbatch Configuration has been overridden for $build_cmd->{NAME}");
            $VTMBTool->info(
"  NBPOOL  old = $pool  :\t NBPOOL  new = $netbatch_override->{$pool}{$class}{$qslot}{'NBPOOL'}"
            );
            $VTMBTool->info(
"  NBCLASS old = $class :\t NBCLASS new = $netbatch_override->{$pool}{$class}{$qslot}{'NBCLASS'}"
            );
            $VTMBTool->info(
"  NBQSLOT old = $qslot :\t NBQSLOT new = $netbatch_override->{$pool}{$class}{$qslot}{'NBQSLOT'}"
            );

            $newpool  = $netbatch_override->{$pool}{$class}{$qslot}{'NBPOOL'};
            $newclass = $netbatch_override->{$pool}{$class}{$qslot}{'NBCLASS'};
            $newqslot = $netbatch_override->{$pool}{$class}{$qslot}{'NBQSLOT'};
            $pool     = $newpool;
            $class    = $newclass;
            $qslot    = $newqslot;
        }
        elsif ( defined $netbatch_override->{$pool}{$class}{$qslot}{'FILTER'}
            && ( $netbatch_override->{$pool}{$class}{$qslot}{'FILTER'} ne "ALL" ) )
        {

            # Determine if the job is part of the hash.
            # BASTARD
            if (
                defined $netbatch_override->{$pool}{$class}{$qslot}{'FILTER'}
                { $build_cmd->{NAME} } )
            {
                $VTMBTool->info(
                    "Netbatch Configuration has been overridden for $build_cmd->{NAME}");
                $VTMBTool->info(
"  NBPOOL  old = $pool  :\t NBPOOL  new = $netbatch_override->{$pool}{$class}{$qslot}{'NBPOOL'}"
                );
                $VTMBTool->info(
"  NBCLASS old = $class :\t NBCLASS new = $netbatch_override->{$pool}{$class}{$qslot}{'NBCLASS'}"
                );
                $VTMBTool->info(
"  NBQSLOT old = $qslot :\t NBQSLOT new = $netbatch_override->{$pool}{$class}{$qslot}{'NBQSLOT'}"
                );

                $newpool  = $netbatch_override->{$pool}{$class}{$qslot}{'NBPOOL'};
                $newclass = $netbatch_override->{$pool}{$class}{$qslot}{'NBCLASS'};
                $newqslot = $netbatch_override->{$pool}{$class}{$qslot}{'NBQSLOT'};
                $pool     = $newpool;
                $class    = $newclass;
                $qslot    = $newqslot;
            }
            elsif (
                defined $netbatch_override->{$pool}{$class}{$qslot}{'FILTER'}{$job_name} )
            {
                $VTMBTool->info(
                    "Netbatch Configuration has been overridden for $job_name");
                $VTMBTool->info(
"  NBPOOL  old = $pool  :\t NBPOOL  new = $netbatch_override->{$pool}{$class}{$qslot}{'NBPOOL'}"
                );
                $VTMBTool->info(
"  NBCLASS old = $class :\t NBCLASS new = $netbatch_override->{$pool}{$class}{$qslot}{'NBCLASS'}"
                );
                $VTMBTool->info(
"  NBQSLOT old = $qslot :\t NBQSLOT new = $netbatch_override->{$pool}{$class}{$qslot}{'NBQSLOT'}"
                );

                $newpool  = $netbatch_override->{$pool}{$class}{$qslot}{'NBPOOL'};
                $newclass = $netbatch_override->{$pool}{$class}{$qslot}{'NBCLASS'};
                $newqslot = $netbatch_override->{$pool}{$class}{$qslot}{'NBQSLOT'};
                $pool     = $newpool;
                $class    = $newclass;
                $qslot    = $newqslot;
            }
            else {
                $VTMBTool->info(
"No Netbatch Configuration has been overridden will be applied for $build_cmd->{NAME}"
                );
            }
        }
        else {
            $VTMBTool->info(
                "No Netbatch Configuration has been overridden for $build_cmd->{NAME}");
        }

    }

# If Mock Turnin and User sets GK_MOCK_NOSUSPEND_CLASS, append NO suspend suffix to class.
    if ( $event_type eq "MOCK" && defined $ENV{'GK_MOCK_NOSUSPEND_CLASS'} ) {
        if ( !defined $build_cmd->{LIST} ) {

            # Depending on NBClass specification, correctly append nosuspend.
            if ( $class =~ /SLES10_EM64T/ ) {
                $new_class = $class . "_nosusp";
                $VTMBTool->info(
                    "Old Format NO_Suspend Class override $class -> $new_class");
                $class = $new_class;
            }
            else {
                $new_class = $class . "&&nosusp";
                $VTMBTool->info(
                    "New Format NO_Suspend Class override $class -> $new_class");
                $class = $new_class;
            }
        }
    }

    # Return the settings
    return ( $pool, $class, $qslot );
}

sub find_nb_settings {
    my $build_cmd_ovrd = shift(@_);
    my $event_type     = shift(@_);
    my $gk_mock_nb_var = shift(@_);
    my $env_nb_var     = shift(@_);
    my $nb_key         = shift(@_);
    my $return_var;

    # Determine which NB Variable Setting is to be used for this job.
    # Order of Precedance.
    # 1) Override by Mock Turnin.
    # 2) Override by GK Event Type
    # 3) Override by GkUtils.* Configuration

    if ( $gk_mock_nb_var && ( $event_type eq "MOCK" ) ) {
        $return_var = $gk_mock_nb_var;
    }
    elsif (( defined $build_cmd_ovrd )
        && ( ref $build_cmd_ovrd eq 'HASH' )
        && ( defined $build_cmd_ovrd->{$event_type} ) )
    {
        $return_var = $build_cmd_ovrd->{$event_type};
    }
    elsif ( ( defined $build_cmd_ovrd ) && ( ref $build_cmd_ovrd eq 'ARRAY' ) ) {
        $VTMBTool->error("A ARRAY used as key for $nb_key is currently not supported.");
        $VTMBTool->check_errors();
    }
    elsif (( defined $build_cmd_ovrd )
        && ( ref $build_cmd_ovrd ne 'HASH' )
        && ( ref $build_cmd_ovrd ne 'ARRAY' ) )
    {
        $return_var = $build_cmd_ovrd;
    }
    else {
        $return_var = $env_nb_var;
    }

    # Return NB Variable.
    return ($return_var);
}

#-------------------------------------------------------------------------------
# find_nb_settings()
#   Find the Correct NB Variable Settings given
#-------------------------------------------------------------------------------
#sub find_nb_settings {
#    my $build_cmd_ovrd = shift(@_);
#    my $event_type     = shift(@_);
#    my $gk_mock_nb_var = shift(@_);
#    my $env_nb_var     = shift(@_);
#    my $nb_key         = shift(@_);
#    my $return_var;
#
#    # Determine which NB Variable Setting is to be used for this job.
#    # Order of Precedance.
#    # 1) Override by Mock Turnin.
#    # 2) Override by GK Event Type
#    # 3) Override by GkUtils.* Configuration
#
#    if ( $gk_mock_nb_var && ( $event_type eq "MOCK" ) ) {
#        $return_var = $gk_mock_nb_var;
#    }
#    elsif (( defined $build_cmd_ovrd )
#        && ( ref $build_cmd_ovrd eq 'HASH' )
#        && ( defined $build_cmd_ovrd->{$event_type} ) )
#    {
#        $return_var = $build_cmd_ovrd->{$event_type};
#
##  if(ref $build_cmd_ovrd eq 'HASH')
##  {
##    # If Hash, determine key by GkEventType
##    if(defined $build_cmd_ovrd->{$event_type})
##     {
##     }
##    else
##     {
##       $VTMBTool->error("No KEY for $ENV{'GK_EVENTTYPE'} is specified in $nb_key override");
##       $VTMBTool->check_errors();
##     }
##
##  }
## elsif(ref  eq 'ARRAY')
##  {
##    $VTMBTool->error("A ARRAY is used as key is currently not supported.");
##    $VTMBTool->check_errors();
##  }
## else
##  {
##    $return_var = $build_cmd_ovrd;
##  }
#    }
#    elsif ( ( defined $build_cmd_ovrd ) && ( ref $build_cmd_ovrd eq 'ARRAY' ) ) {
#        $VTMBTool->error("A ARRAY used as key for $nb_key is currently not supported.");
#        $VTMBTool->check_errors();
#    }
#    elsif (( defined $build_cmd_ovrd )
#        && ( ref $build_cmd_ovrd ne 'HASH' )
#        && ( ref $build_cmd_ovrd ne 'ARRAY' ) )
#    {
#        $return_var = $build_cmd_ovrd;
#    }
#    else {
#        $return_var = $env_nb_var;
#    }
#
#    # Return NB Variable.
#    return ($return_var);
#}

#-------------------------------------------------------------------------------
# dump_netbatch_settings()
#   At conclusion of job, delete all tasks from NBFeeder
#-------------------------------------------------------------------------------
sub dump_netbatch_settings {
    my $perl_obj = shift(@_);
    my $obj_name = shift(@_);
    my $perl_obj_dump =
        $VTMBObj->get('MODEL')
      . "/GATEKEEPER"
      . "/vtmbjob.$ENV{'GK_EVENTTYPE'}.netbatch.pl";
    open( FD, ">$perl_obj_dump" );
    local $Data::Dumper::Purity = 1;
    print FD Data::Dumper->Dump( [$perl_obj], ["$obj_name"] );
    close(FD);
}

#-------------------------------------------------------------------------------
# process_cfg_var()
#   For the CFG Key, determine if hash(GkEventType as key), array or scalar.
#-------------------------------------------------------------------------------
sub process_cfg_var {
    my $cfg_obj     = shift(@_);
    my $cfg_obj_key = shift(@_);
    my $gk_event    = shift(@_);
    my $return_var;

    if ( ref $$cfg_obj->{$cfg_obj_key} eq 'HASH' ) {
        if ( defined $$cfg_obj->{$cfg_obj_key}{ $ENV{'GK_EVENTTYPE'} } ) {
            $return_var = $$cfg_obj->{$cfg_obj_key}{ $ENV{'GK_EVENTTYPE'} };
        }
    }
    elsif ( ref $$cfg_obj->{$cfg_obj_key} eq 'ARRAY' ) {
        $VTMBTool->error("A ARRAY is used as key is currently not supported.");
        $VTMBTool->check_errors();
    }
    else {
        $return_var = $$cfg_obj->{$cfg_obj_key};
    }

    # Return value
    return ($return_var);
}

#-------------------------------------------------------------------------------
# generate_regression_perf_data()
#   Generate Regressions Performance Data from Test Results,
#    and write results to disk.
#-------------------------------------------------------------------------------
sub generate_regression_perf_data {

    # Display status and set up indentation
    #   $VTMBTool->indent_msg(0);
    #   $VTMBTool->info("");
    #   $VTMBTool->indent_msg(2);
    my $vtmb_jobs = shift;

    $VTMBTool->info("Creating Hertz Performance Data for $ENV{'GK_EVENTTYPE'} ");

    # Get BK Head Revision
    my ( $cmd, @cmd_output, $bk_rev, $md5key );

    # Get BK REV of integration area.
    $cmd        = "bk changes -q -m -nd:REV:";
    @cmd_output = `$cmd`;
    $bk_rev     = $cmd_output[0];
    chomp($bk_rev);
    $regress_perf_data{BK_HEAD_REVISION} = $bk_rev;

    # Get MD5key of integration area.
    $cmd        = "bk changes -q -m -nd:MD5KEY:";
    @cmd_output = `$cmd`;
    $md5key     = $cmd_output[0];
    chomp($md5key);
    $regress_perf_data{MD5KEY_HEAD_REVISION} = $md5key;

# Loop Thru regressions and generate hertz data from RPT file using lstp which has been updated to contain hertz(raw) and hertz(normalized)
    foreach my $jobs (@$vtmb_jobs) {
        if ( defined $jobs->{REGRESS_COUNT} ) {
            &read_regression_perf_data( $jobs, \%regress_perf_data );
        }
    }

# If Enabled for the pipeline, place the results on data disk, otherwise place it in GATEKEEPER directory.
    my $hertz_data_results =
      "$ENV{'MODEL'}/GATEKEEPER/gk_regress_perf.$ENV{'GK_EVENTTYPE'}.pm";

    # PERF Data Dumper
    open( FD, ">$hertz_data_results" );
    my $hash_ref = \%regress_perf_data;
    local $Data::Dumper::Purity = 1;
    local $Data::Dumper::Indent = 2;
    print FD Data::Dumper->Dump( [$hash_ref], ["regress_jobs"] );
    close FD;

    # Based on Pipeline Enabling, move PERF result of leave in current location.
    if (   ( defined $Models{hertz_data_cluster_enable} )
        && ( defined $ENV{'GK_TURNIN_ID'} )
        && ( $ENV{'GK_EVENTTYPE'} eq "turnin" ) )
    {
        my $hertz_data_disk =
          "$Models{hertz_data_disk}/$ENV{'GK_CLUSTER'}/$ENV{'GK_STEP'}";
        $VTMBTool->create_directories($hertz_data_disk);
        $VTMBTool->info(
" Place Hertz Performance Data for $ENV{'GK_EVENTTYPE'} here $hertz_data_disk. "
        );

        # If the Turnin is Bundled, Create a copy for each turnin within the bundle.
        if ( $ENV{'GK_BUNDLE_SIZE'} >= 1 ) {
            my @bundle_turnins = split( /\s+/, $ENV{'GK_TURNIN_IDS'} );
            foreach my $gk_turnin_ids (@bundle_turnins) {
                my $ti_result = "$hertz_data_disk/turnin$gk_turnin_ids.regress_perf.pl";
                if ( $VTMBTool->run("cp $hertz_data_results $ti_result") == 0 ) {
                    $VTMBTool->info(
                        "Turnin Regressing PERF result successfully copied to $ti_result"
                    );
                }
                else {
                    $VTMBTool->info(
                        "Turnin Regressing PERF result was NOT successfully copied");
                }
            }
        }

    }
    else {
        $VTMBTool->info(
"Created Hertz Performance Data for $ENV{'GK_EVENTTYPE'} here $hertz_data_results "
        );
    }
}

#-------------------------------------------------------------------------------
# read_regression_perf_data()
#   Read Regressions Performance Data from Test Results area and hash it.
#-------------------------------------------------------------------------------
sub read_regression_perf_data {

    # Display status and set up indentation
    #   $VTMBTool->indent_msg(0);
    #   $VTMBTool->info("");
    #   $VTMBTool->indent_msg(2);

    my $regress_job = shift(@_);
    my $perf_hash   = shift(@_);

    my $rpt       = $regress_job->{RPT_FILE};
    my $dut       = $regress_job->{DUT};
    my $test_list = $regress_job->{TEST_LIST};

    # Get & Process Performance Information
    my ( $cmd, @cmd_output );
    $cmd        = "lstp $rpt";
    @cmd_output = `$cmd`;

    # Include Test Status Information
    $$perf_hash{$dut}{$test_list}{TEST_TOTAL}   = $regress_job->{REGRESS_COUNT};
    $$perf_hash{$dut}{$test_list}{TEST_PASS}    = $regress_job->{PASSING};
    $$perf_hash{$dut}{$test_list}{TEST_FAIL}    = $regress_job->{FAILING};
    $$perf_hash{$dut}{$test_list}{TEST_SKIPPED} = $regress_job->{SKIPPED};

    my (
        $median_hertz,  $median_memory, $max_memory, $min_memory,
        $total_cputime, $total_cycles,  $max_cputime
    );
    foreach my $results (@cmd_output) {
        my @temp = split( /\s+/, $results );
        my (
            $title, $cycles,    $cpu,        $cpuhrs, $wall, $wallhrs,
            $vsize, $hertz_raw, $hertz_nomz, $host,   $platform
        ) = split( /\s+/, $results );

        #           ?       ?            ?              ?      ?          ?
        if ( $results =~ /^min\s+/ ) {
            $$perf_hash{$dut}{$test_list}{CYCLES}{MIN}           = $cycles;
            $$perf_hash{$dut}{$test_list}{CPUTIME}{MIN}          = $cpu;
            $$perf_hash{$dut}{$test_list}{WALLTIME}{MIN}         = $wall;
            $$perf_hash{$dut}{$test_list}{MEMORY}{MIN}           = $vsize;
            $$perf_hash{$dut}{$test_list}{HERTZ}{MIN_RAW}        = $hertz_raw;
            $$perf_hash{$dut}{$test_list}{HERTZ}{MIN_NORMALIZED} = $hertz_raw;
        }
        if ( $results =~ /^max\s+/ ) {
            $$perf_hash{$dut}{$test_list}{CYCLES}{MAX}           = $cycles;
            $$perf_hash{$dut}{$test_list}{CPUTIME}{MAX}          = $cpu;
            $$perf_hash{$dut}{$test_list}{WALLTIME}{MAX}         = $wall;
            $$perf_hash{$dut}{$test_list}{MEMORY}{MAX}           = $vsize;
            $$perf_hash{$dut}{$test_list}{HERTZ}{MAX_RAW}        = $hertz_raw;
            $$perf_hash{$dut}{$test_list}{HERTZ}{MAX_NORMALIZED} = $hertz_raw;
        }
        elsif ( $results =~ /^median\s+/ ) {
            $$perf_hash{$dut}{$test_list}{CYCLES}{MEDIAN}           = $cycles;
            $$perf_hash{$dut}{$test_list}{CPUTIME}{MEDIAN}          = $cpu;
            $$perf_hash{$dut}{$test_list}{WALLTIME}{MEDIAN}         = $wall;
            $$perf_hash{$dut}{$test_list}{MEMORY}{MEDIAN}           = $vsize;
            $$perf_hash{$dut}{$test_list}{HERTZ}{MEDIAN_RAW}        = $hertz_raw;
            $$perf_hash{$dut}{$test_list}{HERTZ}{MEDIAN_NORMALIZED} = $hertz_raw;
        }
        elsif ( $results =~ /^total\s+/ ) {
            $$perf_hash{$dut}{$test_list}{CYCLES}{TOTAL}   = $cycles;
            $$perf_hash{$dut}{$test_list}{CPUTIME}{TOTAL}  = $cpu;
            $$perf_hash{$dut}{$test_list}{WALLTIME}{TOTAL} = $wall;
        }
    }
}

#-------------------------------------------------------------------------------
# PruneVTMBJobs()
#Pruning @VTMBjobs. Once all Jobs are part of @VTMBJobs, see each job's dependency. If the dependency they are dependent on is not present, then remove the job. This will serve multiple purpose. Do this only when $VTMBJob->{'SMART'} = 1 - else it will not catch real depedencies missing.
#1. Compliments Smart build and extends to general_cmds
#-------------------------------------------------------------------------------
sub PruneVTMBJobs {

    my @temp;

    # Display status and set up indentation
    $VTMBTool->indent_msg(0);
    $VTMBTool->info(
"Pruning Build Commands for Models - based on SMART keyword in JobHash if depedency not present"
    );
    $VTMBTool->indent_msg(2);

    #Walk through all the tasks and record their task names
    my %tasknames;
    foreach my $all_task (@VTMBJobs) {
        if ( defined $all_task->{TASK_NAME} ) {
            $tasknames{ $all_task->{TASK_NAME} } = 1;
        }
    }
   # print Dumper \%tasknames;

# Now walk through all the tasks again and see their dependencies. Skip pruning if hash doesn't have any dependency defined. If the defined dependency is not present in %tasknames, then prune this task if "SMART" has been set in this task

    foreach my $all_task (@VTMBJobs) {

        # Loop thru the Task, and determine the ones to keep based on dut or job match.
        if ( not defined $all_task->{SMART} ) {
            next;
        }
        elsif ( ( defined $all_task->{SMART} ) && ( $all_task->{SMART} eq "1" ) ) {
            my @dep_array = @{ $all_task->{DEPENDENCY} };

            #If dependency array is empty. i.e size = -1, then skip
            if ( $#dep_array eq -1 ) {
                next;
            }
            my $found_dep = 0;
            foreach my $task_deps ( @{ $all_task->{DEPENDENCY} } ) {
                if ( defined $tasknames{$task_deps} )
                { #For now, even if single dependency has been found - we don't use multiple dependencies in Gfx yet
                    $found_dep = 1;
                }
            }

    #If no depednecy has been found, then $found_dep = 0. In this case, set PRUNE_TASK = 1
            if ( $found_dep eq 0 ) {

                # Mark Task as one to keep.
                $all_task->set( 'PRUNE_TASK', 1 );
            }
        }
    }
    # Check if any of the dependencies is getting pruned because its dependency is not present and remove the task.
    &checkForNestedDeps();
    #Now iterate through all VTMBJobs again, and remove tasks for which PRUNE_TASK 1

    # Print the names of task that are being kept
    foreach my $all_task (@VTMBJobs) {
        if ( !$all_task->{PRUNE_TASK} ) {
            $VTMBTool->info("Keeping : $all_task->{NAME}");
            push @temp, $all_task;
        }
        elsif ( $all_task->{PRUNE_TASK} ) {
            $VTMBTool->info("Removing task: $all_task->{NAME}");
        }
    }

    # Determine if Jobs have been Pruned, if not give user an error.
    if ( not @temp ) {
        $VTMBTool->error("Error in Pruning Jobs. Please contact Pipeline
          Monitor or gfx.gk.vcoe\@intel.com");
    }

    # Check for Errors.
    $VTMBTool->check_errors();

    # Return
    return @temp;
}

sub checkForNestedDeps{
    my @JobNames;
    my $index;
    foreach my $all_task (@VTMBJobs) {
        if ( defined $all_task->{TASK_NAME}) {
            push (@JobNames,$all_task->{TASK_NAME});
        }
    }
    foreach my $all_task (@VTMBJobs) {
        my @deps = @{$all_task->{DEPENDENCY}};
        foreach my $dep(@deps){
        if ( $dep ~~ @JobNames ){
              $index = indexes{$_ eq $dep} @JobNames;
          }
        }

        if (defined $index && $VTMBJobs[$index]->{PRUNE_TASK} == 1){
            $all_task->set( 'PRUNE_TASK', 1 );
          }
       }
}


#-----------------------------------------------------------------------------------
# GenerateTask4PrunedJobs()
#   Process Pruned VTMBJobs Array, generate the task files now for build, general,
#     and regression jobs.
#-----------------------------------------------------------------------------------
sub GenerateTask4PrunedJobs {
    my $jobs_hash = shift(@_);

    # Display status and set up indentation
    $VTMBTool->indent_msg(0);
    $VTMBTool->info("Generating Task for PrunedJobs");
    $VTMBTool->indent_msg(2);

    # Walk thru the Jobs Hash and Create the Task Files.
    foreach my $jobs (@$jobs_hash) {
        if ( !defined $jobs->{REGRESS_COUNT} ) {

            # Create Build Task
            # Task File Generation will be dependent on CMD_TYPE
            $VTMBTool->info("Generating Build Task for $jobs->{'NAME'}");
            if ( defined $VTMBJob->{CMD_TYPE} && $VTMBJob->{CMD_TYPE} eq "acereg" ) {
                $jobs->create_cshfile($VTMBObj);
                $jobs->create_acereg_taskfile( $VTMBObj, $VTMBTool );
            }
            else {
                if ( defined $VTMBJob->{ENV_FILE} ) {
                    $jobs->create_cshfile($VTMBObj);
                    $jobs->create_taskfile( $VTMBObj, $Models{timeout}{build} );
                }
                else {
                    $jobs->create_taskfile( $VTMBObj, $Models{timeout}{build} );
                }
            }
        }
        else {
            &CreateSimregressTasks( \$jobs );
        }
    }

    # Walk Dependencies of this task.
    # Return hash
    return @$jobs_hash;
}

#-------------------------------------------------------------------------------
# CreateSimregressTasks()
#   Based on the Duts being built. Generate the Regression Jobs
#   Create the Simregress Task file by running simregress cmdline, and grabbing
#   task, testcount, and rpt file.
#-------------------------------------------------------------------------------
sub CreateSimregressTasks {
    my ($job) = @_;

    # Display status and set up indentation
    $VTMBTool->indent_msg(0);
    $VTMBTool->indent_msg(2);

    my ( $cmd, @cmd_results, @cmd_results2, $line, $ward );
    my ( $rpt_file, $job_file, $task_file, @temp );
    my ( $test_count, $j, $task_modelroot );

    # cd to task model_root to support clone in clone where model root might differ.
    $task_modelroot = $$job->{MODEL};
    if ( $task_modelroot ne $ENV{'MODEL'} ) {
        chdir $task_modelroot;
    }

    # Get simregress commandline
    $cmd = $$job->{CMDS};
####################################################################################################################################################
    $VTMBTool->info("Generating NBFeeder Job File for $$job->{'NAME'}");
    if ( $VTMBTool->run( $cmd, \@cmd_results ) == 0 ) {

        # Simregress invocation was successful. CD back to MODEL .
        chdir $ENV{'MODEL'};

        #Grab Location of JOBFile created by simregress
        foreach $line (@cmd_results) {
            if ( $line =~ /^Pwd\s*:/ ) {
                @temp = split( /:/, $line );
                $ward = $temp[-1];
                chomp($ward);
            }
            if ( $line =~ /^Report Name\s*:/ ) {
                @temp = split( /:/, $line );
                $temp[-1] =~ s/^ //;
                $rpt_file = $temp[-1];
                $job_file = $temp[-1];
                $job_file =~ s/\.rpt/\.list\.netbatch_ready/;
                $task_file = $rpt_file;
                $task_file =~ s/\.rpt/\.nbtask_conf/;
                chomp($job_file);
                chomp($rpt_file);
                chomp($task_file);

                if ( $VTMBTool->run( "wc -l $job_file", \@cmd_results2 ) == 0 ) {
                    $VTMBTool->debug("Job File Found:$job_file");
                    $test_count = $cmd_results2[-1];
                    $test_count =~ s/\s.*$//;
                    chomp($test_count);
                }
                else {
                    $VTMBTool->error("Job File Wasn't found :$job_file");
                    last;
                }

                # Update remaining entries in the job hash
                $$job->set( 'JOBFILE',       $job_file );
                $$job->set( 'RPT_FILE',      $rpt_file );
                $$job->set( 'REGRESS_COUNT', $test_count );
                $$job->set( 'TASK_FILE',     $task_file );
            }

            # Grab the Feeder Configuration and Work Area
            if ( $line =~ /^Launch feeder manually, please run\s*:/ ) {
                @temp = split( /:/, $line );
                @temp = split( / /, $temp[-1] );
                for ( $j = 0 ; $j < @temp ; $j++ ) {
                    if ( $temp[$j] =~ /--work-area/ ) {
                        $nbfeeder_ward = $temp[ $j + 1 ];
                    }
                    if ( $temp[$j] =~ /--conf/ ) {
                        $nbfeeder_conf = $temp[ $j + 1 ];
                    }
                }

                # Clean Trash from the NBFeeder path
                $nbfeeder_ward =~ s/\/\//\//;
                $nbfeeder_conf =~ s/\/\//\//;
                $nbfeeder_conf =~ s/]//;
                chomp($nbfeeder_ward);
                chomp($nbfeeder_conf);
                $VTMBTool->info(" Found NBFeeder Work area at     : $nbfeeder_ward");
                $VTMBTool->info(" Found NBFeeder Configuration at : $nbfeeder_conf");
                last;
            }
        }
    }
    else {
        ###     Not needed because the Job hash is already created.
        ###      # Create Job Object
        ###      my $status = (defined $test_list->{GATING} && $test_list->{GATING} == 0) ? "NOT_GATING" : "FAILED";
        ###      $VTMBJob = new VTMBJob
        ###       (
        ###          CMDS        => $cmd,
        ###          DUT         => $test_list->{DUT},
        ###          NAME        => $test_list->{'NAME'},
        ###          DESC        => $test_list->{'DESC'},
        ###          TASK_NAME   => $test_list->{'NAME'},
        ###          NBPOOL      => $job_nbpool,
        ###          NBCLASS     => $job_nbclass,
        ###          NBQSLOT     => $job_nbqslot,
        ###          GATING      => $test_list->{GATING},
        ###          FORCED_FAIL => 1,
        ###          WORKAREA    => $ward . "/LOGS/NBFEEDER",
        ###          MODEL  => $task_modelroot,
        ###       ) or die "Error Initializing VTMBJob Object. Report this bug to GK Owner\n";
        ###
        # Set Status
        my $status =
          ( defined $$job->{GATING} && $$job->{GATING} == 0 ) ? "NOT_GATING" : "FAILED";

        # Set Forced Fail Flag which ic only remaining.
        $$job->set( 'FORCED_FAIL', 1 );

        # Print Results of Error to log file
        foreach $line (@cmd_results) {
            chomp($line);
            $VTMBTool->warning("  $line");
        }

        # If this is a Mock Turnin, mark as warning and but fail the job.
        if ( $GkEventType eq "MOCK" ) {
            $VTMBTool->warning(
                "  simregress invocation failed on testlist $$job->{'LIST'}");

            ###   Not needed Job hash already created.
            ###         # For Mock Turnin we want to Add this job to the Hash, but expect it to Fail.
            ###         $VTMBJob->create_taskfile($VTMBObj);
        }
        elsif ( ( $GkEventType eq "RELEASE" ) && ( $status == "NOT_GATING" ) ) {
            $VTMBTool->warning(
" Not Gating Release simregress invocation failed on testlist $$job->{'LIST'}"
            );

            ###   Not needed Job hash already created.
            ###         # For Releases we want to Add this job to the Hash, but expect it to Fail.
            ###         $VTMBJob->create_taskfile($VTMBObj);
        }
        else {
            $VTMBTool->error(
                "  simregress invocation failed on testlist $$job->{'LIST'}");
        }
    }
####################################################################################################################################################
###   elsif(!$print_commands && $disable_create_taskfile) #Reduce Mode, Disable Task but keep JobHash Settings
###    {
###      $VTMBTool->info("Disabling Task Creation for $job->{'NAME'}, but creating job hash entry for later usage");
###      #Add JobFile to a Jobs Structure
###      $VTMBJob = new VTMBJob
###      (
###        CMDS        => $cmd,
###        DUT         => $test_list->{DUT},
###        NAME        => $test_list->{'NAME'},
###      # JOBFILE     => $job_file,                         # Commented out because simregress has not been run.
###        DESC        => $test_list->{'DESC'},
###        DEPENDENCY_FULL  => [@test_dependency_full],,
###        DEPENDENCY  => [@test_dependency],,
###        DEP_COND    => [@test_dependency_cond],
###      # RPT_FILE    => $rpt_file,                         # Commented out because simregress has not been run.
###        NBCLASS     => $test_list->{'NBCLASS'},
###      # WORKAREA    => $ward . "/LOGS/NBFEEDER",          # Commented out because simregress has not been run.
###        MODEL  => $task_modelroot,
###        TASK_NAME   => $task_name,
###      # TASK_FILE   => $task_file,                        # Commented out because simregress has not been run.
###        REGRESS_COUNT  => 0,                              # Set to 0, will use this later to distinguish Regressions from other job types.
###        TEST_LIST   => $test_list->{LIST},
###        PASS_RATE   => $pass_rate,
###        GATING      => $gating,
###        NBPOOL      => $job_nbpool,
###        NBCLASS     => $job_nbclass,
###        NBQSLOT     => $job_nbqslot,
###        EARLY_KILL_RGRS_CNT => $job_early_kill,
###      ) or die "Error Initializing VTMBJob Object. Report this bug to GK Owner\n";
###      $VTMBTool->debug("  Finished Generating NBFeeder Job File for $test_list->{'NAME'}");
###    }
###   else
###    {
###        # Since this is for commands, filter the strings for readability.
###        $cmd =~ s/$ENV{'MODEL'}\///g if (defined $ENV{'MODEL'});
###        $cmd =~ s/$VTMBObj->{'TASK_PREFIX'}\.//g;
###        $cmd =~ s/-no_run.* -Q\s+\d+\s+//g;
###       #$cmd =~ s/-depends_on.*//g;
###        $cmd =~ s/-depends_on.* -depends_on-//g;
###        if(defined $test_list->{GATING})
###        {
###           $gating = $test_list->{GATING};
###        }
###        else
###        {
###           $gating = 1;
###        }
###        #Add JobFile to a Jobs Structure
###        $VTMBJob = new VTMBJob
###        (
###           CMDS        => $cmd,
###           DUT         => $test_list->{DUT},
###           NAME        => $test_list->{'NAME'},
###           DESC        => $test_list->{'DESC'},
###           DEPENDENCY_FULL => [@test_dependency_full],
###           DEPENDENCY  => [@test_dependency],,
###           DEP_COND => [@test_dependency_cond],
###           NBCLASS     => $test_list->{'NBCLASS'},
###           TASK_NAME   => $task_name,
###           REGRESS_COUNT  => $test_count,
###           PASS_RATE   => $pass_rate,
###           GATING      => $gating,
###           NBPOOL      => $job_nbpool,
###           NBCLASS     => $job_nbclass,
###           NBQSLOT     => $job_nbqslot,
###        ) or die "Error Initializing VTMBJob Object. Report this bug to GK Owner\n";
###        $VTMBTool->debug("  Finished Generating NBFeeder Job File for $test_list->{'NAME'}");
###
###
###    }
### Should already have been done.
###  # Add the Job and Task name to hash.
    $job_2_task_names{ $$job->{'NAME'} } = $$job->{TASK_NAME};
}

#-------------------------------------------------------------------------------
# set_job_type_if_defined()
#   Based on the CFG file, set a job type or return undef.
#-------------------------------------------------------------------------------
sub set_job_type_if_defined {

    # Display status and set up indentation
    $VTMBTool->indent_msg(0);
    $VTMBTool->indent_msg(4);
    my $job_name       = shift(@_);
    my $models_cfg_ref = shift(@_);
    my $job_hash_ref   = shift(@_);
    my $job_type;
    my $reglist_name;

    if ( defined $$job_hash_ref->{JOB_TYPE} ) {
        $job_type = $$job_hash_ref->{JOB_TYPE};
        $VTMBTool->info("Using CFG defined job type to set $job_name to type $job_type");
    }
    elsif ( defined $Models{job_types} ) {
        if ( !defined $$job_hash_ref->{LIST} ) {

            # Build/General Job
            if ( defined $Models{job_types}{ $$job_hash_ref->{CMDS} } ) {
                $job_type = $Models{job_types}{ $$job_hash_ref->{CMDS} };
                $VTMBTool->info("Setting job type for $job_name to type $job_type");
            }
        }
        else {

            # Regression Job
            $reglist_name = basename( $$job_hash_ref->{LIST} );
            if ( defined $Models{job_types}{$reglist_name} ) {
                $job_type = $Models{job_types}{$reglist_name};
                $VTMBTool->info("Setting job type for $job_name to type $job_type");
            }
        }
    }
    else {
        undef $job_type;
    }

    # Return job_type
    return ($job_type);
}

sub get_smart_waiver_jobs{

    my @Models_gen_simb = @{ $Models{general_cmds} };
    push @Models_gen_simb, @{ $Models{simbuild_cmds} };

    # Confirm checks listed in smart waiver mapping config exist and
    # generate their dependencies
    foreach my $c_waive (@smart_waivers){
        my $dut_selected;
        # logic for when duts are selected in smart waiver config as part of extra
        # checks to be run during smart waiver.
        # Format: <waiver_file> => [<check>,<string of comma-separated-checks>]
        # string (array[1]) after <check> is optional, including the duts in parentheses
        if ( $c_waive =~ /\(([\s\S]+)\)/){
            $dut_selected = $1;
            $dut_selected =~ s/^\s+|\s+$//; # Clear leading and trailing spaces
            my @dut_selected = split /\s+/, $dut_selected;
            $dut_selected = join "|", @dut_selected ;
        }

        # Since checks are usually under general commands, iterate thru gen_cmds
        foreach my $general_cmd ( @{ $Models{general_cmds} } ) {
            if ( !($general_cmd->{NAME} =~ /$c_waive/i &&
                    $general_cmd->{DESC} =~ /$c_waive/i &&
                    $general_cmd->{CMDS} =~ /$c_waive/i) ) {
                next;
            }
            # Get duts.
            # @general_cmds hash must have duts defined in 1 of the ff ways
            my @duts;
            if ( $general_cmd->{DUT} ){
                push @duts, $general_cmd->{DUT};
            }
            elsif ( $general_cmd->{DUTS} ){
                @duts = split( / /, $general_cmd->{DUTS} );
            }
            elsif ( $general_cmd->{CMDS} =~ /(-d|--dut)\s+(\S+)\s*/ ) {
                push @duts, $2;
            }

            # Push all the jobs which match the checks and their dependencies
            # into %smart_waiver_tree
            foreach my $dut (@duts){
                # Skip if dut does not match 1 selected in smart_config entry for sWaiver
                if ( $dut_selected and !($dut =~ $dut_selected) ){
                    next;
                }
                my $matched = 0;
                foreach my $item ( @{$smart_waiver_tree{$dut}} ){
                    if (Compare($general_cmd, $item)){
                        $matched = 1;
                        last;
                    }
                }
                $VTMBTool->info("SmartGK-SmartWaiver: Will build check: $c_waive "
                                ."and it's dependecies");
                $VTMBTool->info("SmartGK-SmartWaiver: Adding Job $general_cmd->{NAME}");
                push @{$smart_waiver_tree{$dut}}, $general_cmd if $matched == 0;

                if ( !defined $general_cmd->{DEPENDENCY}){
                    next;
                }

                # Get all dependencies
                my $tmp_cmd = $general_cmd;
                my $no_dep = 0;
                WHL_LOOP: while ( $no_dep == 0 ){
                    $no_dep = 1;
                    my $num_of_dep = scalar (keys $tmp_cmd->{DEPENDENCY});
                    my $dep_index = 0;
                    # This foreach is for jobs with multiple dependencies
                    foreach my $dep (keys $tmp_cmd->{DEPENDENCY}){
                        $dep_index++;
                        FOR_LOOP: foreach my $job (@Models_gen_simb){
                            # Check if dependency is found
                            if ( $dep eq $job->{NAME} ){
                                my $dep_match = 0;
                                # Confirm same job has not been pushed to
                                # @{$smart_waiver_tree{$dut}}
                                foreach ( @{$smart_waiver_tree{$dut}} ){
                                    if (Compare($job, $_)){
                                        $dep_match = 1;
                                        last;
                                    }
                                }
                                $VTMBTool->info("SmartGK-SmartWaiver: Adding "
                                               ."$tmp_cmd->{NAME} Dependency: "
                                               ."$job->{NAME}");
                                push @{$smart_waiver_tree{$dut}}, $job if $dep_match == 0;
                                if ( defined $job->{DEPENDENCY} ){
                                    $tmp_cmd = $job;
                                    $no_dep = 0;
                                    last FOR_LOOP;
                                }
                                if ( !defined $job->{DEPENDENCY} ){
                                    $no_dep = 1;
                                    if ($num_of_dep == $dep_index){
                                        last WHL_LOOP;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

#-------------------------------------------------------------------------------
# set_job_type_if_defined()
#   Based on the CFG file, set a job type or return undef.
#-------------------------------------------------------------------------------
sub perl_hash_data_dumper {
    my $outfile      = shift;
    my $outhash_name = shift;
    my $outhash      = shift;

    # PERF Data Dumper
    $VTMBTool->info("Creating Mock Stats File : $outfile");
    open( FD, ">$outfile" );
    my $hash_ref = \$outhash;
    local $Data::Dumper::Purity = 1;
    local $Data::Dumper::Indent = 2;
    print FD Data::Dumper->Dump( [$hash_ref], ["$outhash_name"] );
    close FD;
}

#-------------------------------------------------------------------------------
# fix_path_var()
#   Swaps the order of /usr/bin and usr/intel/bin to insure /usr/intel/bin always
#    precedes.
#-------------------------------------------------------------------------------
sub fix_path_var {
    my ( $path, @path_vars, $usr_bin, $usr_intel_bin, $i );
    $path      = $ENV{'PATH'};
    @path_vars = split( /:/, $path );
    $i         = 0;
    foreach my $var (@path_vars) {
        if ( $var =~ /^\/usr\/bin$/ ) {
            $usr_bin = $i;
        }
        if ( $var =~ /^\/usr\/intel\/bin$/ ) {
            $usr_intel_bin = $i;
        }

        $i++;
    }

    # Determine if usr_bin is earlier in the path that usr_intel_bin.
    if ( $usr_bin < $usr_intel_bin ) {

        # Swap the entries
        $VTMBTool->info("  PATH Variable needs to be modified.");
        $VTMBTool->info("   Old: $ENV{PATH}");
        $path_vars[$usr_bin]       = "/usr/intel/bin";
        $path_vars[$usr_intel_bin] = "/usr/bin";
        $path = join( ":", @path_vars );
        $VTMBTool->info("   New: $path");
    }
    else {
        $VTMBTool->info("  PATH Variable will not be modified ");
    }
    return ($path);
}

# AT 2/23/2014
# Open the modeldir; some stupid scripts close the write permissions of files in the model
# which causes the cleanup scripts and gkd cleanup of filter/turnin dir to fail
# This causes disk full issues
sub open_model_dir {

    my ( $open_chmod_command, @cmd_results, $line );
    $open_chmod_command = "chmod -R u+w $regress_path/regress";
    $VTMBTool->info("Opening the write permissions on model:$regress_path/regress");
    if ( $VTMBTool->run( $open_chmod_command, \@cmd_results ) != 0 ) {
        $VTMBTool->warning(
            "Unable to open write permissions on model:$regress_path/regress");
        foreach $line (@cmd_results) {
            chomp($line);
            $VTMBTool->warning("  $line");
        }
    }

    return 0;
}

sub trim {
    map {
        s/^\s+//;
        s/\s+$//;
    } @_;
}

# This function returns false if incoming file list doesnt match a given regex

sub isMatching {
    my $files_changed = shift;
    my $regex = shift;
    my @fc = @$files_changed;
    my @reg = @$regex;
    foreach my $i (@reg) {
        chomp $i;
        foreach my $j (@fc) {
            chomp $j;
            $VTMBTool->info("Matching $j with $i");
            if ($j =~ /$i/) {
                $VTMBTool->info("Match found: File: $j matched regex: $i");
                $VTMBTool->info("Additional criteria will be enabled for this run");
                return 0;
            }
        }
    }
    return 1;
}

#Method to check space
sub disk_space_check {

    my $required_size =
        $ENV{'GK_EVENTTYPE'} eq "post-release"
      ? $Models{model_size}{ $ENV{'GK_CLUSTER'} } / 3
      : $Models{model_size}{ $ENV{'GK_CLUSTER'} };    # rough approximation
    unless ( $print_commands
        || $VTMBTool->free_disk_space( $ENV{'MODEL'}, $required_size ) )
    {
        if ( !defined $ENV{'GK_DISABLE_DISK_SPACE_CHECK'} ) {
            $VTMBTool->error(
"Less than the required ${required_size}GB's of Free Space Exists to build $ENV{'GK_CLUSTER'} exists on this disk."
            );
            $VTMBTool->error(" Please Clean up this Disks.");
            $VTMBTool->error(
                "  To turnin off this check: setenv GK_DISABLE_DISK_SPACE_CHECK 1");
        }
        else {
            $VTMBTool->warning(
"Less than the required ${required_size}GB's of Free Space Exists to build $ENV{'GK_CLUSTER'}"
            );
            $VTMBTool->warning(" You have chosen to bypass this message.");
            $VTMBTool->warning("   Jobs could fail unexpectedly.");
            $VTMBTool->warning(
                "     Proceed at your own risk and consider yourself warned.");
        }
    }
}

sub find_appropriate_cache()
{
    my $abs_path = undef;
    if (defined $ENV{GK_PREV_WORK_DIR} && length($ENV{GK_PREV_WORK_DIR}))
    {
           # find realpath to value
           # find commit id to confirm
           my $golden_path = $ENV{GK_PREV_WORK_DIR};
           if ($golden_path =~ /\s+/)
           {
               my @tmp_paths = split /\s+/, $golden_path;
               $golden_path = $tmp_paths[0];
           }
           $abs_path = realpath($golden_path);
           $VTMBTool->info("Golden path - $golden_path\n");
           $VTMBTool->info("Absolute path - $abs_path\n") if (defined $abs_path);
           $VTMBTool->log("Golden path - $golden_path\n");
           $VTMBTool->log("Absolute path - $abs_path\n") if (defined $abs_path);
    }
    else
    {
           use Cwd 'realpath';
           # find last passing model
           if (!defined $ENV{PROJ} || ! defined $ENV{GK_CLUSTER} || ! defined $ENV{GK_STEPPING} || ! defined $ENV{GK_BRANCH})
           {
              return;
           }
           my $golden_path = "$ENV{PROJ}/validation/gatekeeper/GK_WORK_ROOT/turnin/$ENV{GK_CLUSTER}/$ENV{GK_CLUSTER}-$ENV{GK_STEPPING}-$ENV{GK_BRANCH}-latest/";
           $abs_path = realpath($golden_path);
           $VTMBTool->info("Golden path - $golden_path\n");
           $VTMBTool->info("Absolute path - $abs_path\n") if (defined $abs_path);
           $VTMBTool->log("Golden path - $golden_path\n");
           $VTMBTool->log("Absolute path - $abs_path\n") if (defined $abs_path);
    }
    if (defined $abs_path)
    {
        $ENV{GK_CACHE_PATH} = $abs_path;
    }
}

sub check_if_cache_applicable()
{
    return 0 if ((! defined $Models{enableCache}) || ($Models{enableCache} == 0));
    return 0 if (((! defined $Models{enableCacheFilter}) || ($Models{enableCacheFilter} == 0)) && ($ENV{GK_EVENTTYPE} eq "filter") );
    return 0 if (((! defined $Models{enableCacheTurnin}) || ($Models{enableCacheTurnin} == 0)) && ($ENV{GK_EVENTTYPE} eq "turnin") );
    return 0 if (((! defined $Models{enableCacheRelease}) || ($Models{enableCacheRelease} == 0)) && (($ENV{GK_EVENTTYPE} eq "release") || ($ENV{GK_EVENTTYPE} eq "post-release")));
    return 0 if (((! defined $Models{enableCacheMock}) || ($Models{enableCacheMock} == 0)) && ($ENV{GK_EVENTTYPE} eq "mock") );
    if ( !exists $ENV{'GK_BUNDLE_FILES_CHANGED'} ) {
    #if ( !exists $ENV{'GK_FILES_CHANGED'} ) {
        $VTMBTool->log("Check cache: \$GK_BUNDLE_FILES_CHANGED was not set. Fact will run\n");
         return 0;            #FIX ME

    }
    else {
        my $files_changed_cmd = "cat $ENV{'GK_BUNDLE_FILES_CHANGED'}";
        my @files_changed     = qw();
        $VTMBTool->run( $files_changed_cmd, \@files_changed );
        if ($?) {
            $VTMBTool->log("Check cache to be run: Unable to cat [$ENV{'GK_BUNDLE_FILES_CHANGED'}]: $!");
            return 0;
        }
        my @cache_regex;
        if (defined $Models{$ENV{GK_CLUSTER}}{cache_regex}{inclusion})
        {
            @cache_regex = @{$Models{$ENV{'GK_CLUSTER'}}{cache_regex}{inclusion}};
        }
        else
        {
            return 0;
        }

        my %hash_f; # Contains list of paths for which we can use cache
        foreach (@cache_regex)
        {
            my @allf = glob($_[0]);
            foreach my $f (@allf)
            {
               $hash_f{$f} = 1;
            }
        }
        my %files_hash;
        foreach ( @files_changed)
        {
            chomp $_;
            $files_hash{$_} = 0;
        }
        foreach my $f (sort keys %files_hash)
        {
             chomp $f;
             foreach my $reg (sort keys %hash_f)
             {
                 next if ($files_hash{$f} == 1);  # already processed
                 if ($f =~ /^$reg/)
                 {
                       $files_hash{$f} = 1;
                       $VTMBTool->info("File Hash $f: $files_hash{$f} matches $reg\n");
                       $VTMBTool->log("File Hash $f: $files_hash{$f} matches $reg\n");
                       last;
                 }  else {
                       $VTMBTool->debug("File Hash $f: $files_hash{$f} not matches $reg \n");
                 }
             }
        }
        foreach (sort keys %files_hash)
        {
           if ($files_hash{$_} == 0)
           {
                $VTMBTool->debug("Disabling cache due to $_ \n");
                return 0;
           }
        }

        $VTMBTool->info("Enable cache for this bundle \n");
        return 1;
     }
}
