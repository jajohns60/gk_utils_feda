#!/usr/intel/bin/perl -w
#---------------------------------------------------------------------------------------------------
#     Package Name: VTMBLog.pm
#          Project: Haswell
#            Owner: Chancellor Archie(chancellor.archie@intel.com)
#      Description: This package provides a log file object that is used to initialize and write to 
#                   a log file
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


#---------------------------------------------------------------------------------------------------
# Package Info
#---------------------------------------------------------------------------------------------------
package VTMBLog;         # Package name


#---------------------------------------------------------------------------------------------------
# Required Libraries
#---------------------------------------------------------------------------------------------------
use strict;             # Use strict syntax pragma
use VTMBObject;          # All objects derived from VTMBObject


#---------------------------------------------------------------------------------------------------
# Inheritance
#---------------------------------------------------------------------------------------------------
use vars qw(@ISA);
@ISA = qw(VTMBObject);


#---------------------------------------------------------------------------------------------------
# closelog()
#   Closes log file
#---------------------------------------------------------------------------------------------------
sub closelog
{
    # Get class
    my $self = shift;

    # Only destory once
    if (defined $self->{'FPTR'})
    {
        # Display date/time to log file
        my ($date) = `date`;
        print {$self->{'FPTR'}} "Log file completed at $date";

        # Close log file handle
        close($self->{'FPTR'});
        $self->{'FPTR'} = undef;
    }
}


#---------------------------------------------------------------------------------------------------
# new()
#   Object constructor opens & initializes log file - overrides one in VTMBObject
#---------------------------------------------------------------------------------------------------
sub new
{
    # Get class name and dereference if necessary
    my $proto = shift;
    my $class = ref ($proto) || $proto;

    # Initialize object properties and override with user values    
    my ($self) = 
    {
        FPTR            => undef,
        SHOWDATETIME    => 1,
        PATH            => 'log',
        TOOLOBJ         => undef,
        @_,
    };

    # Bless the reference
    bless $self, $class;

    # Make sure reference to tool object was passed
    return undef unless (ref $self->{'TOOLOBJ'});
    
    # Check for existing log file
    my $log = "$self->{'PATH'}";
    if (-e $log) 
    {
        # Figure out unique name
        my ($num) = 1;
        while (-e "$log.$num") 
        {
            $num++;
        }

        # Update property to unique filename
        $self->{'PATH'} = "$log.$num";
    }

    # Create file handle and open file unless existing handle was not supplied
    unless (defined $self->{'FPTR'})
    {
        # Perl trick to create reference to nameless glob 
        local *FPTR;
        $self->{'FPTR'} = do { local *FPTR };
        
        # Open log file or die
        open($self->{'FPTR'}, ">$self->{'PATH'}") or $self->{'TOOLOBJ'}->fatal("Could not open log file $self->{'PATH'} ($!)");
    }
    
    # Write out current date/time
    $self->write('Log file started on ' . `date`);
        
    # Register this log object with the tool object or fail
    $self->{'TOOLOBJ'}->register('LOGOBJ', $self) or $self->{'TOOLOBJ'}->fatal('Could not register log file (VTMBTool->register(LOGOBJ)).  Report this bug to DA.');

    # Return the reference
    return $self;
}


#---------------------------------------------------------------------------------------------------
# write( message )
#   Writes a line to the log file
#---------------------------------------------------------------------------------------------------
sub write
{
    # Get class and message
    my ($self, $msg) = @_;

    # Prepend date/time to log if SHOWDATATIME
    if ($self->{'SHOWDATETIME'} == 1)
    {
        my $datetime = `date \"+%m/%d %H:%M:%S\"`;
        chomp($datetime);
        $msg = "[$datetime] $msg";
    }

    # Make sure file has been opened
    if (defined $self->{'FPTR'})
    {
        # Display message to log file
        print {$self->{'FPTR'}} $msg;
    }
    #else
    #{
    #    print 'In VTMBLog::write(' . $msg . ') but FPTR is not defined' . "\n";
    #}      
}


1;
