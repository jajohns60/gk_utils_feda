#!/usr/intel/pkgs/perl/5.26.1/bin/perl
# -*- mode: perl; indent-tabs-mode: nil; perl-indent-level: 2; cperl-indent-level: 2; -*-

## Pragmas
use strict;
use warnings;

## Include Paths
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

## Modules
use Cwd;
use Data::Dumper;
use File::Basename;
use File::Spec;
use Getopt::Long;
use GkConfig;
use GkUtil qw(:DEFAULT :print);

## Variables
$GkConfig::systemRoot = $systemRoot;
GkUtil::set_prefix(basename($0));

my %OPT =
  (
   diff => "diff",
   build_regress_script => "gk-utils.pl",
   output_dir => "/tmp",
   project => $ENV{PROJECT},
   tool_root => "$ENV{RTL_PROJ_TOOLS}/gk-utils",
   config_root => "$ENV{RTL_PROJ_TOOLS}/gk-configs",
   gkcfgdir => $ENV{GK_CONFIG_DIR},
   release_root => $ENV{RTLMODELS},
   use_model => 1,
  );

GetOptions(\%OPT,
     "clusters|c=s@",
     "steppings|s=s@",
     "branches|b=s@",
     "events|e=s@",
     "project=s",
     "gkcfgdir=s",
     "tool_root=s",
     "config_root|cfg_root=s",
     "release_root=s",
     "build_regress_script|script=s",
     "output_dir=s",
     "diff=s",
     "ver1|v1=s",
     "ver2|v2=s",
     "cfg1|c1=s",
     "cfg2|c2=s",
     "model1|m1=s",
     "model2|m2=s",
     "debug|d",
     "graph|g!"
    );

GkUtil::set_debug($OPT{debug});

my ($check_ver, $check_cfg, $check_model);

if ($OPT{ver1} && $OPT{ver2}) {
  $check_ver = 1;
  &info("Using different gk-utils versions");
} elsif (!$OPT{ver1} && !$OPT{ver2}) {
  $OPT{ver1} = $GkConfig::systemRoot;
  &info("Using current version of gk-utils by default");
}

if ($OPT{cfg1} && $OPT{cfg2}) {
  $check_cfg = 1;
  &info("Using different gk-configs versions");
} elsif (!$OPT{cfg1} && !$OPT{cfg2}) {
  if ($ENV{GK_CONFIG_DIR}) {
    $OPT{cfg1} = $ENV{GK_CONFIG_DIR};
    &info("Using \$GK_CONFIG_DIR for gk-configs by default");
  } else {
    &fatal_error("Must specify at least one version of gk-configs (-cfg[12])");
  }
}

if (!$ENV{GK_CONFIG_DIR}) {
  my $cfgdir;

  if ($OPT{gkcfgdir}) {
    $cfgdir = $OPT{gkcfgdir};
  } else {
    $cfgdir = $OPT{cfg1} || $OPT{cfg2};
    &info("Using first version of gk-configs for loading config (use -gkcfgdir to change): ${cfgdir}");
  }
  $ENV{GK_CONFIG_DIR} = $cfgdir;
}

if ($OPT{model1} && $OPT{model2}) {
  $check_model = 1;
  &info("Using different model versions");
} elsif (!$OPT{model1} && !$OPT{model2}) {
  if ($ENV{MODEL_ROOT}) {
    $OPT{model1} = $ENV{MODEL_ROOT};
    &info("Using \$MODEL_ROOT for model by default");
  } else {
    &fatal_error("Must specify at least one model version (-model[12])");
  }
}

if (!$check_ver && !$check_cfg && !$check_model) {
  &fatal_error("Must specify at least one pair of versions of the following: gk-utils (-ver[12]), gk-configs (-cfg[12]), models (-model[12])");
}

GkConfig::load_GkConfig();

my %opt_steppings = map { $_ => 1 } @{$OPT{steppings}};
my %opt_clusters = map { $_ => 1 } @{$OPT{clusters}};
my %opt_branches = map { $_ => 1 } @{$OPT{branches}};
my %opt_events = map { $_ => 1 } @{$OPT{events}};

my (@repos, %repo_2_cluster, %repo_2_stepping, %repo_2_branch, @events);
my ($repo_cluster, $repo_step, $repo_branch);
my @GK_EVENTTYPES = qw(mock filter turnin release post-release);
# Create Tag dump file
my $USER = $ENV{USER};


## Code

&info("Valid Steppings = " . join(", ", @{$GkConfig{validDisplaySteppings}}));
&info("Valid Clusters  = " . join(", ", @{$GkConfig{validDisplayClusters}}));
&info("Valid Branches  = " . join(", ", @{$GkConfig{validDisplayBranches}}));
foreach my $stepping (@{$GkConfig{validDisplaySteppings}}) {
  next if (@{$OPT{stepping}} && ! exists $opt_steppings{$stepping});

  foreach my $cluster (@{$GkConfig{validDisplayClusters}}) {
    next if (@{$OPT{cluster}} && ! exists $opt_clusters{$cluster});

    foreach my $branch (@{$GkConfig{validDisplayBranches}}) {
      next if (@{$OPT{branch}} && ! exists $opt_branches{$branch});

      my $master_repo = $GkConfig{repo_name_template};
      $master_repo =~ s/PROJECT/$OPT{project}/g;
      $master_repo =~ s/CLUSTER/$cluster/g;
      $master_repo =~ s/STEPPING/$stepping/g;
      $master_repo =~ s/BRANCH/$branch/g;

      push(@repos, $master_repo);
      $repo_2_cluster{$master_repo} = $cluster;
      $repo_2_stepping{$master_repo} = $stepping;
      $repo_2_branch{$master_repo} = $branch;
    }
  }
}

my @repo_names = map {
    "$repo_2_stepping{$_}/$repo_2_cluster{$_}/$repo_2_branch{$_}"
} @repos;
&info("Selected Steppings/Clusters/Branches = " . join(", ", @repo_names));

&info("Valid Events = " . join(", ", @GK_EVENTTYPES));
foreach my $event (@GK_EVENTTYPES) {
  my $found = 0;
  if (@{$OPT{events}} && (exists $opt_events{$event})) {
    $found = 1;
  } elsif (!@{$OPT{events}}) {
    $found = 1;
  }

  if ($found) {
    push(@events, $event);
  }
}

&info("Selected Events = " . join(", ", @events));

print "\n";
foreach my $repo (@repos) {
  $repo_cluster = $repo_2_cluster{$repo};
  $repo_step = $repo_2_stepping{$repo};
  $repo_branch = $repo_2_branch{$repo};

  foreach my $gk_event (@events) {
    &info(" $repo_step $repo_cluster $repo_branch $gk_event");
    &diff_gk_utils_versions(
      [@OPT{qw(ver1 ver2)}],
      [@OPT{qw(cfg1 cfg2)}],
      [@OPT{qw(model1 model2)}],
      $repo_cluster, $repo_step, $repo_branch, $gk_event);
  }
  print "\n";
}

exit(0);


## Subroutines
sub diff_gk_utils_versions {
  my ($vers_ref, $cfgs_ref, $models_ref, $cluster, $stepping, $branch, $gk_event) = @_;

  my $curr_dir = Cwd::getcwd();

  my $i = 0;
  my @files = ();
  my @versions = map { $_ || () } @$vers_ref;
  my @cfgs = map { $_ || () } @$cfgs_ref;
  my @models = map { $_ || () } @$models_ref;

  foreach my $i (1 .. 2) {
    my $ver = (@versions > 1)? $versions[$i - 1] : $versions[0];
    my $cfg = (@cfgs > 1)? $cfgs[$i - 1] : $cfgs[0];
    my $model = (@models > 1)? $models[$i - 1] : $models[0];
    &debug("VER${i}: ${ver}, CFG${i}: ${cfg}, MODEL${i}: ${model}");

    my $real_ver;
    my $real_ver_path;
    my $ver_path;
    if (-d $ver) {
      $ver_path = Cwd::abs_path($ver);
      $real_ver_path = $ver_path;
      $real_ver = basename($ver_path);
    } else {
      $real_ver_path = Cwd::abs_path("$OPT{tool_root}/${ver}");
      $real_ver = basename($real_ver_path);
      $ver_path = "$OPT{tool_root}/${real_ver}";
    }

    my $real_cfg;
    my $cfg_path;
    if (-d $cfg) {
      $cfg_path = Cwd::abs_path($cfg);
      $real_cfg = basename($cfg_path);
    } else {
      $real_cfg = basename(Cwd::abs_path("$OPT{config_root}/${cfg}"));
      $cfg_path = "$OPT{config_root}/${real_cfg}";
    }

    my $real_model;
    my $model_path;
    if (-d $model) {
      $model_path = Cwd::abs_path($model);
      $real_model = basename($model_path);
    } else {
      my $model_prefix = $GkConfig{repo_name_template};
      $model_prefix =~ s/PROJECT/$OPT{project}/g;
      $model_prefix =~ s/CLUSTER/$cluster/g;
      $model_prefix =~ s/STEPPING/$stepping/g;
      $model_prefix =~ s/BRANCH/$branch/g;

      if (-d "$OPT{release_root}/${cluster}/${model}") {
        $real_model = basename(Cwd::abs_path("$OPT{release_root}/${cluster}/${model}"));
        $model_path = "$OPT{release_root}/${cluster}/${real_model}";
      } elsif (-d "$OPT{release_root}/${cluster}/${model_prefix}-${model}") {
        $real_model = basename(Cwd::abs_path("$OPT{release_root}/${cluster}/${model_prefix}-${model}"));
        $model_path = "$OPT{release_root}/${cluster}/${real_model}";
      }
    }

    my $cmd = "${ver_path}/$OPT{build_regress_script} -gkcfgdir ${cfg_path} -c ${repo_cluster} -s ${repo_step} -${gk_event}";
    if ($OPT{graph}) {
      $cmd .= " -dependency_graph";
    } else {
      $cmd .= " -commands";
    }

    my @cmd_result;

    {
      local %ENV = %ENV;
      if ($OPT{use_model}) {
        if ($model_path) {
          if (-d $model_path) {
            &debug("Setting MODEL_ROOT '${model_path}'");
          } else {
            &fatal_error("MODEL_ROOT '${model_path}' Does Not Exist for $stepping/$cluster/$branch");
          }
        } else {
          &fatal_error("MODEL_ROOT Does Not Exist for $stepping/$cluster/$branch");
        }
        $ENV{MODEL_ROOT} = $model_path;
        chdir($model_path);
      } else {
        delete($ENV{MODEL_ROOT});
        chdir($OPT{output_dir});
      }

      &debug("Running Command '${cmd}'");
      @cmd_result = `${cmd}`;
      chdir($curr_dir);
    }

    my $file = "$OPT{output_dir}/$i.$USER.$stepping.$cluster.$branch.$gk_event";
    push(@files, $file);

    &debug("Writing Output File '${file}'");
    if (open my $output_fh, q{>}, $file) {
      foreach my $line (@cmd_result) {
        $line =~ s|\Q${ver_path}\E|<gk-utils-version>|g;
        $line =~ s|\Q${real_ver_path}\E|<gk-utils-version>|g;
        $line =~ s|\Q${model_path}\E|<model-root>|g;
        $line =~ s|\Q${cfg_path}\E|<gk-configs-version>|g;

        my $real_model_path = Cwd::abs_path($model_path);
        $line =~ s|\Q${real_model_path}\E|<model-root>|g;

        my $fake_release_model_path = File::Spec->catdir($OPT{release_root}, $cluster, $real_model);
        $line =~ s|\Q${fake_release_model_path}\E|<model-root>|g;

        $line =~ s|\Q${real_model}\E|<model-name>|g;

        print {$output_fh} "${line}";
      }
      close $output_fh;
    }
  }

  my $diff_cmd = "$OPT{diff} -b " . join(" ", @files);
  &debug("Running Command '${diff_cmd}'");
  my @cmd_result = `${diff_cmd}`;
  print $_ foreach (@cmd_result);
  print "\n" if (@cmd_result);
}
