#!/usr/intel/bin/perl -w
#-------------------------------------------------------------------------------
#     Package Name: VTMBObject.pm
#          Project: Haswell/Broadwell
#            Owner: Chancellor Archie (chancellor.archie@intel.com)
#      Description: This package was original developed for CedarMill DFT Tools, and Chancellor
#                   utilized them for DA tool development. They have been leveraged to VTMB.
#                   This package is a root object that all other objects are derived from. 
#                      
# 
# 
#   (C) Copyright Intel Corporation, 2008
#   Licensed material -- Program property of Intel Corporation
#   All Rights Reserved
#  
#   This program is the property of Intel Corporation and is furnished
#   pursuant to a written license agreement. It may not be used, reproduced,
#   or disclosed to others except in accordance with the terms and conditions
#   of that agreement
#--------------------------------------------------------------------------------
 
#-------------------------------------------------------------------------------
## Required Libraries
##-------------------------------------------------------------------------------
package VTMBObject; # Package name
use strict;         # Use strict syntax pragma

#-------------------------------------------------------------------------------
## new(hash of initial property values)
## Generic object constructor
##-------------------------------------------------------------------------------
sub new 
{
    my $class = shift;
    my $self;

    # Initialize object properties and override with user values if specified.
    $self = { 
              GK_ENV        => {},                   # Gate Keeper Environment 
              GK_CLUSTER    => $ENV{'GK_CLUSTER'},   # Gate Keeper Cluster setting
              GK_STEP       => $ENV{'GK_STEP'},      # Gate Keeper Stepping Setting
              GK_EVENTTYPE  => $ENV{'GK_EVENTTYPE'}, # Type of Gate Keeper Event
              GK_ID         => undef,                # Gate Keeper Record Id.
              MODEL    => undef,                # RTL MODEL 
              TASK_PREFIX   => undef,                # Prefix to Append to All Task Names
	      TASK_TAG	    => undef,                # A uniqe task tag
              user          => $ENV{'USER'},         # Name of User if GKType is Turnin
                                                     # Name will be Bkuser if Release.
              startTime     => time(),               # Time object was created
              @_,
            }; 

    #Bless the reference and return it.
    bless $self, $class;
    return $self;
}

#-------------------------------------------------------------------------------
## get(Object property name, new value)
##   write value of given Object property
##-------------------------------------------------------------------------------
sub set
{
   # Get Object type, Object property name, value to be set
   my ($self,$objprop,$objvalue) = @_;

   # Check if the Object Property Exists, if it does set it, 
   # Error 
   if(exists $self->{$objprop})
    {
      $self->{$objprop} = $objvalue;
      return 1;
    }
   else
    {
      die "Object Property $objprop does not exists in $self";  
    }
}
#-------------------------------------------------------------------------------
## get(Object property name)
##   Reads Object property and returns the value.
##-------------------------------------------------------------------------------
sub get
{
   # Get Object type, Object property name, value to be set
   my ($self,$objprop) = @_;

   # Return Value of Object Property if it Exists, else return error.
   if(exists $self->{$objprop})
    {
      return $self->{$objprop};
    }
   else
    {
      die "Object Property $objprop does not exists in $self";  
    }
}

#-------------------------------------------------------------------------------
## register(type, object reference)
##   Registers an object with the tool
##------------------------------------------------------------------------------
sub register
{   
    # Get class type, and object reference 
    my ($self, $type, $ref) = @_;
            
    # Make sure it is a reference
    if(ref($ref))
      {
         # Set the property to this reference
         $self->{$type} = $ref;
         return 1;
      }
    # Otherwise return false
    else
      {
        return 0;
      }
}

1;
