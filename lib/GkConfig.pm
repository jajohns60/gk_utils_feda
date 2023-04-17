#!/usr/intel/pkgs/perl/5.26.1/bin/perl

package GkConfig;

use strict;
use warnings;

use parent qw(Exporter);
our @EXPORT = qw($systemRoot %GkConfig $dev_config %cfg_common %Models %QCConfig);
our @EXPORT_OK = qw(&load_GkConfig &load_GkUtilsConfig);

use File::Spec::Functions qw(catdir);
use GkUtil qw(:DEFAULT :print);

use vars qw($systemRoot %GkConfig $dev_config %cfg_common %Models %QCConfig);

##---------------------------------------------------------------------------------------------------
## load_GkConfig()
##   load GkConfig file based on GK search rules
##---------------------------------------------------------------------------------------------------
sub load_GkConfig {
  my ($cfg) = @_;
  my $message;

  my $dir_var = "GK_CONFIG_DIR";
  my $cfgdir = $ENV{$dir_var};
  my ($prefix, $suffix) = qw(GkConfig pl);
  my $dev_mode = $ENV{GK_DEV};

  if (!$cfg) {
    &fatal_error("${dir_var} not defined when trying to load ${prefix} File") unless ($cfgdir);

    my %field_values =
      (
       project  => $ENV{GK_PROJECT} || $ENV{PROJECT},
       cluster  => $ENV{GK_CLUSTER},
       stepping => $ENV{GK_STEP} || $ENV{GK_STEPPING},
       branch   => $ENV{GK_BRANCH},
      );

    my @combinations =
      (
       [qw(project stepping cluster branch)],
       [qw(project stepping cluster)],
       [qw(project stepping branch)],
       [qw(project cluster branch)],
       [qw(project stepping)],
       [qw(project cluster)],
       [qw(project branch)],
       [qw(project)],
       [qw(stepping cluster branch)],
       [qw(stepping cluster)],
       [qw(stepping branch)],
       [qw(cluster branch)],
       [qw(stepping)],
       [qw(cluster)],
       [qw(branch)],
       [],
      );

    my ($used_field_list, $dev_cfg);
    ($cfg, $used_field_list, $dev_cfg) = &get_config_file($prefix, $suffix, $cfgdir,
                                                          \%field_values, \@combinations,
                                                          $dev_mode);

    if ($cfg) {
      if (@$used_field_list) {
        $message = "Using " . join(' & ', map { (ucfirst $_), } @$used_field_list) . " Specific";
      } else {
        $message = "Using General";
      }
      $message .= " DEV" if ($dev_cfg);
      $message .= " GK Configuration File: ${cfg}";
    } else {
      &fatal_error("Could not find valid GkConfig file.");
    }

    &info($message) if ($message && !&GkUtil::is_quiet());
  } elsif ($cfg !~ m|^/|) {
    $cfgdir ||= ".";
    $cfg = catdir($cfgdir, $cfg);
  }

  &load_config_file($cfg, {fatal => 1});
  return $cfg;
}                               # sub load_GkConfig

##---------------------------------------------------------------------------------------------------
## load_GkUtilsConfig()
##   load gk-utils Config file based on GK/gk-utils search rules
##---------------------------------------------------------------------------------------------------
sub load_GkUtilsConfig {
  my ($cfg) = @_;
  my $message;

  my $dir_var = "GK_UTILS_CONFIG_DIR";
  my $cfgdir = $ENV{$dir_var};
  my ($prefix, $suffix) = qw(GkUtils cfg);
  my $dev_mode = $ENV{GK_DEV};

  if (!$cfg) {
    &fatal_error("${dir_var} not defined when trying to load ${prefix} File") unless ($cfgdir);

    my %field_values =
      (
       project   => $ENV{GK_PROJECT} || $ENV{PROJECT},
       cluster   => $ENV{GK_CLUSTER},
       stepping  => $ENV{GK_STEP} || $ENV{GK_STEPPING},
       branch    => $ENV{GK_BRANCH},
       event     => $ENV{GK_EVENTTYPE},
      );

    my @combinations =
      (
       [qw(project stepping cluster branch event)],
       [qw(project stepping cluster branch)],
       [qw(project stepping cluster event)],
       [qw(project stepping cluster)],
       [qw(project stepping branch)],
       [qw(project cluster branch event)],
       [qw(project cluster branch)],
       [qw(project stepping event)],
       [qw(project stepping)],
       [qw(project cluster event)],
       [qw(project cluster)],
       [qw(project branch event)],
       [qw(project branch)],
       [qw(project event)],
       [qw(project)],
       [qw(stepping cluster branch event)],
       [qw(stepping cluster branch)],
       [qw(stepping cluster event)],
       [qw(stepping cluster)],
       [qw(stepping branch event)],
       [qw(stepping branch)],
       [qw(cluster branch event)],
       [qw(cluster branch)],
       [qw(stepping event)],
       [qw(stepping)],
       [qw(cluster event)],
       [qw(cluster)],
       [qw(branch event)],
       [qw(branch)],
       [qw(event)],
       [],
      );

    my ($used_field_list, $dev_cfg);
    ($cfg, $used_field_list, $dev_cfg) = &get_config_file($prefix, $suffix, $cfgdir,
                                                          \%field_values, \@combinations,
                                                          $dev_mode);

    if ($cfg) {
      if (@$used_field_list) {
        $message = "Using " . join(' & ', map { (ucfirst $_), } @$used_field_list) . " Specific";
      } else {
        $message = "Using General";
      }
      $message .= " DEV" if ($dev_cfg);
      $message .= " GK Utils Configuration File: ${cfg}";
    } else {
      &fatal_error("Could not find valid GkUtils Configuration file.");
    }

    &info($message) if ($message && !&GkUtil::is_quiet());
  } elsif ($cfg !~ m|^/|) {
    $cfgdir ||= ".";
    $cfg = catdir($cfgdir, $cfg);
  }

  &load_config_file($cfg, {fatal => 1});
  return $cfg;
}                               # sub load_GkUtilsConfig

##---------------------------------------------------------------------------------------------------
## load_QCConfig()
##   load QCConfig file based on QC search rules
##---------------------------------------------------------------------------------------------------
sub load_QCConfig {
  my ($cfg) = @_;
  my $message;

  my $dir_var = "QC_CONFIG_DIR";
  my $cfgdir = $ENV{$dir_var};
  my ($prefix, $suffix) = qw(QCConfig pl);

  if (!$cfg) {
    &fatal_error("${dir_var} not defined when trying to load ${prefix} File") unless ($cfgdir);

    my %field_values =
      (
       project  => $ENV{GK_PROJECT} || $ENV{PROJECT},
       cluster  => $ENV{GK_CLUSTER},
       stepping => $ENV{GK_STEP} || $ENV{GK_STEPPING},
       branch   => $ENV{GK_BRANCH},
      );

    my @combinations =
      (
       [qw(project stepping cluster branch)],
       [qw(project stepping cluster)],
       [qw(project stepping branch)],
       [qw(project cluster branch)],
       [qw(project stepping)],
       [qw(project cluster)],
       [qw(project branch)],
       [qw(project)],
       [qw(stepping cluster branch)],
       [qw(stepping cluster)],
       [qw(stepping branch)],
       [qw(cluster branch)],
       [qw(stepping)],
       [qw(cluster)],
       [qw(branch)],
       [],
      );

    my ($used_field_list);
    ($cfg, $used_field_list) = &get_config_file($prefix, $suffix, $cfgdir,
                                                \%field_values, \@combinations);

    if ($cfg) {
      if (@$used_field_list) {
        $message = "Using " . join(' & ', map { (ucfirst $_), } @$used_field_list) . " Specific";
      } else {
        $message = "Using General";
      }
      $message .= " QC Configuration File: ${cfg}";
    }

    &info($message) if ($message && !&GkUtil::is_quiet());
  } elsif ($cfg !~ m|^/|) {
    $cfgdir ||= ".";
    $cfg = catdir($cfgdir, $cfg);
  }

  &load_config_file($cfg, {fatal => 1});
  return $cfg;
}                               # sub load_QCConfig

##---------------------------------------------------------------------------------------------------
## get_config_file()
##   Return the name of the found config file given the prefix, suffix, a hash of values and the order
##   of fields
##   If dev is set, then return the dev config file.
##---------------------------------------------------------------------------------------------------
sub get_config_file {
  my ($prefix, $suffix, $dir, $values_ref, $combos_ref, $dev) = @_;

  my $cfg_file = undef;
  my $used_fields = [];
  my $dev_cfg = 0;
  my @dev_modes = ();
  if ($dev) {
    @dev_modes = (1, 0);
  } else {
    @dev_modes = (0);
  }

  # Configuration file has the format:
  #
  #    GkConfig.[$project].[stepping].[cluster].[branch].pl
  #
  # Code will use the first one found.  Stepping, Cluster, and Branch are each option.

  SEARCH: foreach my $combo (@$combos_ref) {
    foreach my $dev_mode (@dev_modes) {
      my $file = &create_config_name($prefix, $suffix, $values_ref, $combo, $dev_mode);
      next unless ($file);

      my $path = catdir($dir, $file);
      &debug("Looking for config file: ${path}");
      if (-f $path) {
        $cfg_file = $path;
        $used_fields = $combo;
        $dev_cfg = $dev_mode;
        last SEARCH;
      }
    }
  }

  return ($cfg_file, $used_fields, $dev_cfg);
}                               # sub get_config_file

##---------------------------------------------------------------------------------------------------
## create_config_name()
##   Return the name of the config file given the prefix, suffix, a hash of values and the order
##   of fields
##   If dev is set, then return the dev config file.
##---------------------------------------------------------------------------------------------------
sub create_config_name {
  my ($prefix, $suffix, $values_ref, $order_ref, $dev) = @_;
  my $file = $prefix;

  if ($order_ref) {
    foreach my $key (@$order_ref) {
      if ((defined $key) && $values_ref->{$key}) {
        $file .= ".$values_ref->{$key}";
      } else {
        return;
      }
    }
  }
  $file .= ".dev" if ($dev);
  $file .= ".${suffix}";

  return $file;
}                               # sub create_config_name

##---------------------------------------------------------------------------------------------------
## load_config_file()
##   Attempt to load the given config file
##   Return the error status if fatal not set
##---------------------------------------------------------------------------------------------------
sub load_config_file {
  my ($cfg, $mode_hash) = @_;
  $mode_hash = {} unless ((ref $mode_hash) eq 'HASH');
  $cfg ||= "";

  my $fatal = $$mode_hash{fatal};
  my $error_string;

  if (-e $cfg) {
    ## Access the configuration File
    &info("Loading Config File: ${cfg}") if (!&GkUtil::is_quiet());
    if (!(my $return = do $cfg)) {
      if ($@) {
        $error_string = "Could not parse ${cfg}: ${@}";
      } elsif (!(defined $return)) {
        $error_string = "Could not do ${cfg}: ${!}";
      } else {
        $error_string = "Could not run ${cfg}";
      }
    }
  } else {
    $error_string = "Config file '${cfg}' not found when trying to load config file.";
  }

  if ($error_string) {
    if ($fatal) {
      &fatal_error($error_string);
    } else {
      &error($error_string);
    }
  }

  return $error_string;
}                               # sub load_config_file

##---------------------------------------------------------------------------------------------------
## get_repo_name_template()
##   Return the pipeline repository name template
##   If substitute is set to 1, perfrom the substituions of environment variables into the template
##---------------------------------------------------------------------------------------------------
sub get_repo_name_template {
  my ($substitute, $release) = @_;

  my $project = $ENV{PROJECT};
  my $cluster = $ENV{GK_CLUSTER};
  my $stepping = $ENV{GK_STEP} || $ENV{GK_STEPPING};
  my $branch = $ENV{GK_BRANCH};

  my $template;

  if ($release && $GkConfig{release_name_template}) {
    $template = $GkConfig{release_name_template};
  } elsif ($cluster && $GkConfig{repo_name_template_cluster} &&
      (defined $GkConfig{repo_name_template_cluster}{$cluster})) {
    $template = $GkConfig{repo_name_template_cluster}{$cluster};
  } elsif ($stepping && $GkConfig{repo_name_template_stepping} &&
           (defined $GkConfig{repo_name_template_stepping}{$stepping})) {
    $template = $GkConfig{repo_name_template_cluster}{$stepping};
  } elsif ($branch && $GkConfig{repo_name_template_branch} &&
           (defined $GkConfig{repo_name_template_branch}{$branch})) {
    $template = $GkConfig{repo_name_template_cluster}{$branch};
  } else {
    $template = $GkConfig{repo_name_template} || "CLUSTER-ertl-STEPPING";
  }

  if ($substitute) {
    $template =~ s/CLUSTER/${cluster}/g if ($cluster);
    $template =~ s/STEPPING/${stepping}/g if ($stepping);
    $template =~ s/BRANCH/${branch}/g if ($branch);
    $template =~ s/PROJECT/${project}/g if ($project);
  }

  return $template;
}                               # sub get_repo_name_template

1;
