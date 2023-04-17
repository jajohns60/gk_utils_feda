#!/usr/intel/bin/perl -w
#---------------------------------------------------------------------------------------------------
#     Package Name: VTMBCmdline.pm
#          Project: Haswell/Broadwell
#            Owner: Chancellor Archie (chancellor.archie@intel.com)
#      Description: This package was original developed for CedarMill DFT Tools, and Chancellor
#                   utilized them for DA tool development. They have been leveraged to VTMB.
#                   This package provides functions to parse a command line and display command 
#                   line help.
#
#
#  (C) Copyright Intel Corporation, 2003
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
package VTMBCmdline;         # Package name


#---------------------------------------------------------------------------------------------------
# Required Libraries
#---------------------------------------------------------------------------------------------------
use strict;                 # Use strict syntax pragma
use VTMBObject;              # All objects derived from VTMBObject


#---------------------------------------------------------------------------------------------------
# Inheritance
#---------------------------------------------------------------------------------------------------
use vars qw(@ISA);
@ISA = qw(VTMBObject);


#---------------------------------------------------------------------------------------------------
# Package Variables
#---------------------------------------------------------------------------------------------------
my $SCREEN_WIDTH = 80;


#---------------------------------------------------------------------------------------------------
# display_help()
#   Displays command line help page
#---------------------------------------------------------------------------------------------------
sub display_help 
{
    # Get class name
    my $self = shift;

    $self->{'TOOLOBJ'}->indent_msg(0);
    $self->{'TOOLOBJ'}->info("Displaying command line help ...");

    # Display tool identification string
    print "\n\n" . $self->{'TOOLOBJ'}->identify() . "\n\n\n";
    
    # Display description with indent
    print "Description:\n\n";
    my @strings;
    if ($self->{'AUTO_WRAP'})
    {
        @strings = &wrap_string($self->{'DESCRIPTION'}, $SCREEN_WIDTH - 4);
    }
    else
    {
        @strings = split(/\n/, $self->{'DESCRIPTION'});
    }
    
    foreach (@strings)
    {
        print " " x 4 . "$_\n";
    }
    print "\n\n";
    
    # Display usage header
    print "Usage:  " . $self->{'TOOLOBJ'}->get('NAME') . " [options]\n\n";
    
    # Figure out longest argument name
    my $long = 0;
    foreach (keys %{$self->{'ARGUMENTS'}})
    {
        # Skip if HIDDEN=1
        next if exists $self->{'ARGUMENTS'}->{$_}->{'HIDDEN'} && $self->{'ARGUMENTS'}->{$_}->{'HIDDEN'}==1;

        # Add on aliases
        my $arg = $_;
        if (exists $self->{'ARGUMENTS'}->{$_}->{'ALIAS'})
        {
            foreach my $alias (split(/\|/, $self->{'ARGUMENTS'}->{$_}->{'ALIAS'}))
            {
                $arg .= '|' . $alias;
            }
        }

        $long = length $arg if (length $arg > $long);
    }
    
    # Display each argument name and description in alphabetical order
    foreach my $arg (sort keys %{$self->{'ARGUMENTS'}})
    {
        # Skip if HIDDEN=1
        next if exists $self->{'ARGUMENTS'}->{$arg}->{'HIDDEN'} && $self->{'ARGUMENTS'}->{$arg}->{'HIDDEN'}==1;
    
        # Get description for this argument, if it exists
        my $desc = "";
        if (exists $self->{'ARGUMENTS'}->{$arg}->{'DESCRIPTION'})
        {
            $desc = $self->{'ARGUMENTS'}->{$arg}->{'DESCRIPTION'};
        }
        
        # Add Required/Optional to description
        if (exists $self->{'ARGUMENTS'}->{$arg}->{'REQUIRED'} && $self->{'ARGUMENTS'}->{$arg}->{'REQUIRED'} == 1)
        {
            $desc .= " Required.";
        }
        else
        {
            $desc .= " Optional.";
        }
        
        # Add default value to description, if it exists
        if (exists $self->{'ARGUMENTS'}->{$arg}->{'DEFAULT'})
        {
            $desc .= "  (Default: $self->{'ARGUMENTS'}->{$arg}->{'DEFAULT'})";
        }

        # Restrict description to available width unless there is less than 10 characters left
        my @lines = ();
        
        # Check if auto wrap is enabled and perform automatic word wrap
        if ($self->{'AUTO_WRAP'})
        {
            if ($long < $SCREEN_WIDTH-10)
            {
                @lines = &wrap_string($desc, $SCREEN_WIDTH-2-$long);
            }

            # Otherwise don't indent descriptions to end of argument name
            else
            {
                @lines = &wrap_string($desc, $SCREEN_WIDTH-4);          
            }
        }
        
        # Otherwise assume string contains embedded newlines
        else
        {
            @lines = split(/\n/, $desc);
        }

        # Add on aliases
        my $string = $arg;
        if (exists $self->{'ARGUMENTS'}->{$arg}->{'ALIAS'})
        {
            foreach my $alias (split(/\|/, $self->{'ARGUMENTS'}->{$arg}->{'ALIAS'}))
            {
                $string .= '|' . $alias;
            }
        }

        # Print leading spaces to align argument names
        print "\n" . " " x ($long - length $string) . "$string: ";
        
        # Print first line of description on same line unless argument name is too long
        if ($long < $SCREEN_WIDTH-10)
        {
            print(shift(@lines) . "\n");
            
            # Print out the rest of the lines and indent over to end of argument name
            foreach (@lines)
            {
                print " " x ($long+2) . "$_\n";
            }
        }
        
        # Otherwise print descriptions on seperate line with smaller indent
        else
        {
            foreach (@lines)
            {
                print " " x 4 . "$_\n";
            }
        }
    }

    # Generate error unless there is an even number of items in example array
    if (scalar @{$self->{'EXAMPLES'}} % 2 != 0)
    {
        $self->{'TOOLOBJ'}->fatal("Invalid examples.  Report this error to DA.");
    }

    # Display examples
    my @examples = @{$self->{'EXAMPLES'}};
    if (scalar @examples > 0)
    {
        print "\n\nExamples:\n\n";
        while (@examples)
        {
            # Display example description
            my @desc;
            if ($self->{'AUTO_WRAP'})
            {
                @desc = &wrap_string(shift @examples, $SCREEN_WIDTH - 4);
            }
            else
            {
                @desc = split(/\n/, shift @examples);
            }

            foreach (@desc)
            {
                print " " x 4 . "$_\n";
            }

            # Display example command line
            my @cmdline = &wrap_string(shift @examples, $SCREEN_WIDTH - 8);
            foreach (@cmdline)
            {
                print " " x 8 . "$_\n";
            }
            print "\n";
        }
    }
    print "\n";
}


#---------------------------------------------------------------------------------------------------
# identify()
#   Returns string of entire command line used
#---------------------------------------------------------------------------------------------------
sub identify
{
    # Return command line used
    my $return_value = "";
    foreach (@ARGV)
    {
        if (/\s+/)
        {
            $return_value .= "\"$_\" ";
        }
        else
        {
            $return_value .= "$_ ";
        }
    }
    return $return_value;
}


#---------------------------------------------------------------------------------------------------
# new(hash of initial property values)
#   Object constructor - overrides generic one from VTMBObject
#---------------------------------------------------------------------------------------------------
sub new
{
    # Get class name and dereference if necessary
    my $proto = shift;
    my $class = ref ($proto) || $proto;

    # Initialize object properties and override with user values    
    my ($self) = 
    {
        ARGUMENTS   => undef,
        AUTO_WRAP   => 1,
        DESCRIPTION => undef,
        EXAMPLES    => undef,
        IGNORE_LAST => undef,
        SUBTOOL     => undef,
        TOOLOBJ     => undef,
        USE_COMMON  => 0,
        @_,
    };

    # Make sure reference to tool object was passed
    unless (ref $self->{'TOOLOBJ'}) {
        return undef;
    }
    
    # Add standard common arguments if needed
    if ($self->{'USE_COMMON'} > 0)
    {
        $self->{'ARGUMENTS'}->{'-breakpoint'} =     
        {   
            ALIAS       =>  '-b',
            HIDDEN  =>  1,
            TYPE        =>  'string',
            DESCRIPTION =>  'Forces tool to exit and named breakpoint.'
        };

        $self->{'ARGUMENTS'}->{'-debug'} =     
        {   
            ALIAS       =>  '-d',
            HIDDEN  =>  1,
            TYPE        =>  'flag',
            DESCRIPTION =>  'Displays debugging messages.'
        };

        $self->{'ARGUMENTS'}->{'-help'} =     
        {   
            ALIAS       =>  '-h',
            TYPE        =>  'flag',
            STANDALONE  =>  1,
            DESCRIPTION =>  'Displays command line help.'
        };
    }      

    # Add extended common arguments if needed
    if ($self->{'USE_COMMON'} > 1)
    {
        $self->{'ARGUMENTS'}->{'-showcommands'} =     
        {   
            TYPE        =>  'flag',
            DESCRIPTION =>  'Shows system commands on both screen and log file.'
        };

        $self->{'ARGUMENTS'}->{'-skipwarnings'} =     
        {   
            TYPE        =>  'flag',
            DESCRIPTION =>  'Does not prompt to continue after warning messages.'
        };
    }

    # Register this cmdline object with the tool object
    unless ($self->{'TOOLOBJ'}->register('CMDLINEOBJ', \$self))
    {
        $self->{'TOOLOBJ'}->fatal("Could not execute VTMBTool->register(CMDLINEOBJ).  Report this bug to DA.");
    }

    # Bless the reference and return it 
    bless $self, $class;
    return $self;
}


#---------------------------------------------------------------------------------------------------
# parse()
#   Parse the command line and check for problems
#---------------------------------------------------------------------------------------------------
sub parse 
{
    # Get class name
    my $self = shift;
    
    # Grab the command line and store into a local variable
    my @args = @ARGV;
    
    # Remember if we see a STANDALONE argument
    my $standalone = 0;
    
    # Remember which arguments have been used
    my %args_used;
    
    # Check for duplicate aliases
    my %alias_hash = ();
    foreach my $arg (keys %{$self->{'ARGUMENTS'}})
    {
        if (exists $self->{'ARGUMENTS'}->{$arg}->{'ALIAS'})
        {
            my @aliases = split(/\|/, $self->{'ARGUMENTS'}->{$arg}->{'ALIAS'});
            foreach my $alias (@aliases)
            {
                if (exists $alias_hash{$alias})
                {
                    $self->{'TOOLOBJ'}->fatal("Duplicate command line argument alias $alias found (for $arg and $alias_hash{$alias}).  Please report this bug to DA.");
                }
                else
                {
                    $alias_hash{$alias} = $arg;
                }
            }
        }
    }    
    
    # Process each item on the command line and store the associated values
    ARG: while (my $item = shift @args)
    {
        # If argument is not recognized, check for aliases
        unless (exists $self->{'ARGUMENTS'}->{$item})
        {
            # No alias found by default
            my $found = 0;
            
            # Look for aliases for all defined arguments
            foreach my $arg (keys %{$self->{'ARGUMENTS'}})
            {
                if (exists $self->{'ARGUMENTS'}->{$arg}->{'ALIAS'})
                {
                    # There may be multiple aliases (delimited by '|' character)
                    my @aliases = split(/\|/, $self->{'ARGUMENTS'}->{$arg}->{'ALIAS'});
                    foreach my $alias (@aliases)
                    {
                        if ($alias eq $item)
                        {
                            # Found alias so expand it to full argument name
                            $item = $arg;
                            $found = 1;
                        }
                    }
                }
            }
            
            # Generate error unless an alias was found
            unless ($found)
            {
                # If IGNORE_LAST = 1 and this is the last argument then skip error
                if ($self->{'IGNORE_LAST'} and scalar(@args)==0)
                {
                    # Store the value of this argument in IGNORE_LAST
                    $self->{'ARGUMENTS'}->{'IGNORE_LAST'}->{'VALUE'} = $item;
                }
                else
                {
                    $self->{'TOOLOBJ'}->error("The command line argument '$item' is not recognized");
                }
                next ARG;
            }
        }
        
        # Check for duplicate arguments
        if (exists $args_used{$item})
        {
            $self->{'TOOLOBJ'}->info("The argument $item was found more than once.  Only the last instance will be used.");
        }
        $args_used{$item} = 1;
        
        # Check if this is a standalone argument
        if (exists $self->{'ARGUMENTS'}->{$item}->{'STANDALONE'})
        {
            $standalone = 1;
        }
        
        # Get argument type
        my $type = $self->{'ARGUMENTS'}->{$item}->{'TYPE'};
        
        # If argument is of type "flag", set value to 1
        if ($type eq 'flag')
        {
            $self->{'ARGUMENTS'}->{$item}->{'VALUE'} = 1;
            next ARG;
        }
        
        # If argument is of type "string", set value to the string
        if ($type eq 'string')
        {
            # Make sure a value was supplied
            if (scalar @args == 0)
            {
                $self->{'TOOLOBJ'}->error("Expected value after argument $item");   
                next ARG;
            }              
        
            # Give warning if the string looks like another argument
            else
            {
                my $value = shift @args;
                if ($value =~ /^-/)
                {
                    $self->{'TOOLOBJ'}->info("The value '$value' for '$item' looks like an argument");
                }
                $self->{'ARGUMENTS'}->{$item}->{'VALUE'} = $value;
                next ARG;
            }
        }
        
        # If argument is of type "integer", set value to the integer
        if ($type eq 'integer')
        {
            # Give error if the value is not an integer
            my $value = shift @args;
            if ($value !~ /^[+\-]?\d+$/)
            {
                $self->{'TOOLOBJ'}->error("The value '$value' for '$item' must be an integer");
            }
            $self->{'ARGUMENTS'}->{$item}->{'VALUE'} = $value;
            next ARG;
        }
        
        # If argument is of type "subtool", make sure all arguments are supported
        if ($type eq 'subtool')
        {
            # Process each sub tool argument
            my @subargs = split(/ /, shift @args);
            foreach (@subargs)
            {
                # Skip unless this looks like an argument
                next unless (/^-/);

                # Generate error if argument is unsupported
                if (exists $self->{'SUBTOOL'}->{'UNSUPPORTED'})
                {
                    $self->{'TOOLOBJ'}->error("Sub tool argument $_ is unsupported");
                }
            
                # Generate error if argument is reserved
                elsif (exists $self->{'SUBTOOL'}->{'RESERVED'})
                {
                    $self->{'TOOLOBJ'}->error("Sub tool argument $_ is reserved by this tool");
                }
            }
            $self->{'ARGUMENTS'}->{$item}->{'VALUE'} = join(' ', @subargs);
            next ARG;
        }
        
        # Otherwise argument type is not recognized so generate error
        $self->{'TOOLOBJ'}->error("The type '$type' for '$item' is invalid.  Report error to DA.");
    }
    
    # Apply default values to missing arguments
    foreach my $arg (keys %{$self->{'ARGUMENTS'}})
    {
        if (exists $self->{'ARGUMENTS'}->{$arg}->{'DEFAULT'} && !exists $self->{'ARGUMENTS'}->{$arg}->{'VALUE'})
        {
            $self->{'ARGUMENTS'}->{$arg}->{'VALUE'} = $self->{'ARGUMENTS'}->{$arg}->{'DEFAULT'};
            $self->{'TOOLOBJ'}->info("Applying default value of " . $self->{'ARGUMENTS'}->{$arg}->{'DEFAULT'} . " to argument $arg");
        }
    }
    
    # Ensure all required arguments were supplied
    foreach my $arg (keys %{$self->{'ARGUMENTS'}})
    {
        if (exists $self->{'ARGUMENTS'}->{$arg}->{'REQUIRED'} && $self->{'ARGUMENTS'}->{$arg}->{'REQUIRED'} == 1)
        {
            # Generate error unless this argument was provided or a standalone argument was used
            unless (defined $self->{'ARGUMENTS'}->{$arg}->{'VALUE'} or $standalone)
            {
                $self->{'TOOLOBJ'}->error("The $arg argument is required");
            }
        }
    }
    
    # Set flags if common arguments were used
    if ($self->{'USE_COMMON'})
    {
        # Set breakpoint flag if needed
        if (exists $self->{'ARGUMENTS'}->{"-breakpoint"} and exists $self->{'ARGUMENTS'}->{"-breakpoint"}->{'VALUE'})
        {
            $self->{'TOOLOBJ'}->set('BREAKPOINT', $self->{'ARGUMENTS'}->{"-breakpoint"}->{'VALUE'});
        }
        
        # Set debug flag if needed
        if (exists $self->{'ARGUMENTS'}->{"-debug"} and exists $self->{'ARGUMENTS'}->{"-debug"}->{'VALUE'})
        {
            $self->{'TOOLOBJ'}->set('DEBUG', 1);
        }
        
        # Set no FlowDB flag if needed
        if (exists $self->{'ARGUMENTS'}->{"-noflowdb"} and exists $self->{'ARGUMENTS'}->{"-noflowdb"}->{'VALUE'})
        {
            $self->{'TOOLOBJ'}->set('USE_FLOWDB', 0);
        }

        # Set command echo flag if needed
        if (exists $self->{'ARGUMENTS'}->{"-showcommands"} and exists $self->{'ARGUMENTS'}->{"-showcommands"}->{'VALUE'})
        {
            $self->{'TOOLOBJ'}->set('COMMAND_ECHO', 1);
        }

        # Set warning prompt flag if needed
        if (exists $self->{'ARGUMENTS'}->{"-skipwarnings"} and exists $self->{'ARGUMENTS'}->{"-skipwarnings"}->{'VALUE'})
        {
            $self->{'TOOLOBJ'}->set('WARNING_PROMPT', 0);
        }
    }      

    # Display help if requested
    if (exists $self->{'ARGUMENTS'}->{'-help'} and exists $self->{'ARGUMENTS'}->{"-help"}->{'VALUE'})
    {
        $self->display_help();
        $self->{'TOOLOBJ'}->terminate();
    }
}


#---------------------------------------------------------------------------------------------------
# value(argument)
#   Returns value of argument
#---------------------------------------------------------------------------------------------------
sub value 
{
    # Get class name and argument
    my ($self, $arg) = @_;
    
    # Return value of argument or undef if it doesn't exist
    if (exists $self->{'ARGUMENTS'}->{$arg} && exists $self->{'ARGUMENTS'}->{$arg}->{'VALUE'}) 
    {
        return $self->{'ARGUMENTS'}->{$arg}->{'VALUE'};
    }
    else
    {
        return undef;
    }   
}


#---------------------------------------------------------------------------------------------------
# wrap_string(string, max width)
#   Breaks a string into an array of lines of a maximum width
#---------------------------------------------------------------------------------------------------
sub wrap_string
{
    # Get string, max width
    my ($string, $width) = @_;
    
    # Return undef if no string provided
    return undef if (!defined $string or length $string == 0);
    
    # Return string if width is greater than length
    return ($string) if (length $string < $width);

    # Break string into words
    my @words = split(/\s+/, $string);
    
    # Initialize variables  
    my $cur_len = 0;
    my $cur_line = "";
    my @lines = ();

    # Create array of strings by adding words until maximum width is reached
    while (defined ($_ = shift @words))
    {
        # Add word to current line if it will fit
        if ($cur_len + length $_ <= ($width-1))
        {
            $cur_line .= "$_ ";
            $cur_len = length($cur_line);
        }
        
        # Otherwise start a new line and add this word to it
        else
        {
            # If this word alone is longer than max width, break it up
            if (length $_ > $width)
            {
                # Get individual characters
                my @chars = split(//, $_);
                
                # Fit as many as possible on current line
                while ($cur_len < $width)
                {
                    $cur_line .= shift @chars;
                    $cur_len = length $cur_line;
                }
                
                # Throw rest of word back on stack
                unshift @words, join('', @chars);
            }

            # Otherwise start new line and add word to it
            else
            {
                push @lines, $cur_line;
                $cur_line = "$_ ";
                $cur_len = length($cur_line);
            }
        }
        
        # Start a new line if no more words can fit
        if ($cur_len >= ($width - 2))
        {
            push @lines, $cur_line;
            $cur_line = "";
            $cur_len = 0;
        }
    }
    
    # Add remaining line unless length is 0
    push @lines, $cur_line unless ($cur_len == 0);
    
    # Return array of strings
    return @lines;
}
    

1;
