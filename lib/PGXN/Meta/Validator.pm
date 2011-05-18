package PGXN::Meta::Validator;

use 5.010;
use strict;
use warnings;
use SemVer;

=head1 Name

PGXN::Meta - Validate PGXN distribution metadata structures

=head1 Synopsis

  my $struct = decode_json_file('META.json');

  my $pmv = PGXN::Meta::Validator->new( $struct );

  unless ( $pmv->is_valid ) {
      my $msg = "Invalid META structure. Errors found:\n";
      $msg .= join( "\n", $pmv->errors );
      die $msg;
  }

=head1 Description

This module validates a PGXN Meta structure against the version of the the
specification claimed in the C<meta-spec> field of the structure.

=cut

#--------------------------------------------------------------------------#
# This code copied and adapted from CPAN::Meta::Valicator by
# David Golden <dagolden@cpan.org> and Ricardo Signes <rjbs@cpan.org>,
# which in turn adapted and copied it from Test::CPAN::Meta
# by Barbie, <barbie@cpan.org> for Miss Barbell Productions,
# L<http://www.missbarbell.co.uk>
#--------------------------------------------------------------------------#

#--------------------------------------------------------------------------#
# Specification Definitions
#--------------------------------------------------------------------------#

my %known_specs = (
    '1.0.0' => 'http://pgxn.org/spec/1.0.0/'
);
my %known_urls = map {$known_specs{$_} => $_} keys %known_specs;

my $no_index = {
    'map'       => { file       => { list => { value => \&string } },
                     directory  => { list => { value => \&string } },
                    ':key'      => { name => \&custom_2, value => \&anything },
    }
};

my $prereq_map = {
  map => {
    ':key' => {
      name => \&phase,
      'map' => {
        ':key'  => {
          name => \&relation,
          'map' => { ':key' => { name => \&module, value => \&exversion } }
        },
      },
    }
  },
};

my %definitions = (
    '1.0.0' => {
        # REQUIRED
        'abstract'            => { mandatory => 1, value => \&string  },
        'maintainer'          => { mandatory => 1, lazylist => { value => \&string } },
        'generated_by'        => { mandatory => 1, value => \&string  },
        'license'             => { mandatory => 1, lazylist => { value => \&license } },
        'meta-spec' => {
            mandatory => 1,
            'map' => {
                version => { mandatory => 1, value => \&version},
                url     => { value => \&url },
                ':key' => { name => \&custom_2, value => \&anything },
            }
        },
        'name'                => { mandatory => 1, value => \&string  },
        'release_status'      => { mandatory => 1, value => \&release_status },
        'version'             => { mandatory => 1, value => \&version },
        'provides'    => {
            'mandatory' => 1,
            'map'       => {
                ':key' => {
                    name  => \&module,
                    'map' => {
                        file     => { mandatory => 1, value => \&file },
                        version  => { value => \&version },
                        abstract => { mandatory => 0, value => \&string  },
                        docfile  => { mandatory => 0, value => \&file },
                        ':key' => { name => \&custom_2, value => \&anything },
                    }
                }
            }
        },

        # OPTIONAL
        'description' => { value => \&string },
        'tags'    => { lazylist => { value => \&string } },
        'no_index' => $no_index,
        'prereqs' => $prereq_map,
        'resources'   => {
            'map'       => {
                license    => { lazylist => { value => \&url } },
                homepage   => { value => \&url },
                bugtracker => {
                    'map' => {
                        web => { value => \&url },
                        mailto => { value => \&string},
                        ':key' => { name => \&custom_2, value => \&anything },
                    }
                },
                repository => {
                    'map' => {
                        web => { value => \&url },
                        url => { value => \&url },
                        type => { value => \&string },
                        ':key' => { name => \&custom_2, value => \&anything },
                    }
                },
                ':key'     => { value => \&string, name => \&custom_2 },
            }
        },

        # CUSTOM -- additional user defined key/value pairs
        # note we can only validate the key name, as the structure is user defined
        ':key'        => { name => \&custom_2, value => \&anything },
    },
);

#--------------------------------------------------------------------------#
# Code
#--------------------------------------------------------------------------#

=head1 Interface

=head2 Constructor

=head3 C<new>

  my $pmv = PGXN::Meta::Validator->new( $struct )

The constructor must be passed a metadata structure.

=cut

sub new {
  my ($class,$data) = @_;

  # create an attributes hash
  my $self = {
    'data'    => $data,
    'spec'    => $data->{'meta-spec'}{'version'} || "1.0.0",
    'errors'  => undef,
  };

  # create the object
  return bless $self, $class;
}

=head2 Instance Methods

=head3 C<is_valid>

  if ( $pmv->is_valid ) {
    ...
  }

Returns a boolean value indicating whether the metadata provided
is valid.

=cut

sub is_valid {
    my $self = shift;
    my $data = $self->{data};
    my $spec_version = $self->{spec};
    $self->check_map($definitions{$spec_version}, $data);
    return ! $self->errors;
}

=head3 C<errors>

  warn( join "\n", $pmv->errors );

Returns a list of errors seen during validation.

=cut

sub errors {
    my $self = shift;
    return () unless defined $self->{errors};
    return @{$self->{errors}};
}

=begin internals

=head2 Check Methods

=over

=item * check_map($spec,$data)

Checks whether a map (or hash) part of the data structure conforms to the
appropriate specification definition.

=item * check_list($spec,$data)

Checks whether a list (or array) part of the data structure conforms to
the appropriate specification definition.

=item * check_lazylist($spec,$data)

Checks whether a list conforms, but converts strings to a single-element list

=back

=cut

my $spec_error = "Missing validation action in specification. "
  . "Must be one of 'map', 'list', 'lazylist', or 'value'";

sub check_map {
    my ($self,$spec,$data) = @_;

    if(ref($spec) ne 'HASH') {
        $self->_error( "Unknown META specification, cannot validate." );
        return;
    }

    if(ref($data) ne 'HASH') {
        $self->_error( "Expected a map structure from string or file." );
        return;
    }

    for my $key (keys %$spec) {
        next    unless($spec->{$key}->{mandatory});
        next    if(defined $data->{$key});
        push @{$self->{stack}}, $key;
        $self->_error( "Missing mandatory field, '$key'" );
        pop @{$self->{stack}};
    }

    for my $key (keys %$data) {
        push @{$self->{stack}}, $key;
        if($spec->{$key}) {
            if($spec->{$key}{value}) {
                $spec->{$key}{value}->($self,$key,$data->{$key});
            } elsif($spec->{$key}{'map'}) {
                $self->check_map($spec->{$key}{'map'},$data->{$key});
            } elsif($spec->{$key}{'list'}) {
                $self->check_list($spec->{$key}{'list'},$data->{$key});
            } elsif($spec->{$key}{'lazylist'}) {
                $self->check_lazylist($spec->{$key}{'lazylist'},$data->{$key});
            } else {
                $self->_error( "$spec_error for '$key'" );
            }

        } elsif ($spec->{':key'}) {
            $spec->{':key'}{name}->($self,$key,$key);
            if($spec->{':key'}{value}) {
                $spec->{':key'}{value}->($self,$key,$data->{$key});
            } elsif($spec->{':key'}{'map'}) {
                $self->check_map($spec->{':key'}{'map'},$data->{$key});
            } elsif($spec->{':key'}{'list'}) {
                $self->check_list($spec->{':key'}{'list'},$data->{$key});
            } elsif($spec->{':key'}{'lazylist'}) {
                $self->check_lazylist($spec->{':key'}{'lazylist'},$data->{$key});
            } else {
                $self->_error( "$spec_error for ':key'" );
            }


        } else {
            $self->_error( "Unknown key, '$key', found in map structure" );
        }
        pop @{$self->{stack}};
    }
}

# if it's a string, make it into a list and check the list
sub check_lazylist {
    my ($self,$spec,$data) = @_;

    if ( defined $data && ! ref($data) ) {
      $data = [ $data ];
    }

    $self->check_list($spec,$data);
}

sub check_list {
    my ($self,$spec,$data) = @_;

    if(ref($data) ne 'ARRAY') {
        $self->_error( "Expected a list structure" );
        return;
    }

    if(defined $spec->{mandatory}) {
        if(!defined $data->[0]) {
            $self->_error( "Missing entries from mandatory list" );
        }
    }

    for my $value (@$data) {
        push @{$self->{stack}}, $value || "<undef>";
        if(defined $spec->{value}) {
            $spec->{value}->($self,'list',$value);
        } elsif(defined $spec->{'map'}) {
            $self->check_map($spec->{'map'},$value);
        } elsif(defined $spec->{'list'}) {
            $self->check_list($spec->{'list'},$value);
        } elsif(defined $spec->{'lazylist'}) {
            $self->check_lazylist($spec->{'lazylist'},$value);
        } elsif ($spec->{':key'}) {
            $self->check_map($spec,$value);
        } else {
          $self->_error( "$spec_error associated with '$self->{stack}[-2]'" );
        }
        pop @{$self->{stack}};
    }
}

=head2 Validator Methods

=over

=item * header($self,$key,$value)

Validates that the header is valid.

Note: No longer used as we now read the data structure, not the file.

=item * url($self,$key,$value)

Validates that a given value is in an acceptable URL format

=item * urlspec($self,$key,$value)

Validates that the URL to a META specification is a known one.

=item * string_or_undef($self,$key,$value)

Validates that the value is either a string or an undef value. Bit of a
catchall function for parts of the data structure that are completely user
defined.

=item * string($self,$key,$value)

Validates that a string exists for the given key.

=item * file($self,$key,$value)

Validate that a file is passed for the given key. This may be made more
thorough in the future. For now it acts like \&string.

=item * exversion($self,$key,$value)

Validates a list of versions, e.g. '<= 5, >=2, ==3, !=4, >1, <6, 0'.

=item * version($self,$key,$value)

Validates a single version string. Versions of the type '5.8.8' and '0.00_00'
are both valid. A leading 'v' like 'v1.2.3' is also valid.

=item * boolean($self,$key,$value)

Validates for a boolean value. Currently these values are '1', '0', 'true',
'false', however the latter 2 may be removed.

=item * license($self,$key,$value)

Validates that a value is given for the license. Returns 1 if an known license
type, or 2 if a value is given but the license type is not a recommended one.

=item * custom_1($self,$key,$value)

Validates that the given key is in CamelCase, to indicate a user defined
tag and only has characters in the class [-_a-zA-Z].  In version 1.X
of the spec, this was only explicitly stated for 'resources'.

=item * custom_2($self,$key,$value)

Validates that the given key begins with 'x_' or 'X_', to indicate a user
defined tag and only has characters in the class [-_a-zA-Z]

=item * identifier($self,$key,$value)

Validates that key is in an acceptable format for the META specification,
for an identifier, i.e. any that matches the regular expression
qr/[a-z][a-z_]/i.

=item * module($self,$key,$value)

Validates that a given key is in an acceptable module name format, e.g.
'Test::PGXN::Meta::Version'.

=back

=end internals

=cut

sub header {
    my ($self,$key,$value) = @_;
    if(defined $value) {
        return 1    if($value && $value =~ /^--- #YAML:1.0/);
    }
    $self->_error( "file does not have a valid YAML header." );
    return 0;
}

sub release_status {
  my ($self,$key,$value) = @_;
  if(defined $value) {
    my $version = $self->{data}{version} || '';
    if ( $version =~ /_/ ) {
      return 1 if ( $value =~ /\A(?:testing|unstable)\z/ );
      $self->_error( "'$value' for '$key' is invalid for version '$version'" );
    }
    else {
      return 1 if ( $value =~ /\A(?:stable|testing|unstable)\z/ );
      $self->_error( "'$value' for '$key' is invalid" );
    }
  }
  else {
    $self->_error( "'$key' is not defined" );
  }
  return 0;
}

# _uri_split taken from URI::Split by Gisle Aas, Copyright 2003
sub _uri_split {
     return $_[0] =~ m,(?:([^:/?#]+):)?(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?,;
}

sub url {
    my ($self,$key,$value) = @_;
    if(defined $value) {
      my ($scheme, $auth, $path, $query, $frag) = _uri_split($value);
      unless ( defined $scheme && length $scheme ) {
        $self->_error( "'$value' for '$key' does not have a URL scheme" );
        return 0;
      }
      unless ( defined $auth && length $auth ) {
        $self->_error( "'$value' for '$key' does not have a URL maintainerity" );
        return 0;
      }
      return 1;
    }
    $value ||= '';
    $self->_error( "'$value' for '$key' is not a valid URL." );
    return 0;
}

sub urlspec {
    my ($self,$key,$value) = @_;
    if(defined $value) {
        return 1    if($value && $known_specs{$self->{spec}} eq $value);
        if($value && $known_urls{$value}) {
            $self->_error( 'META specification URL does not match version' );
            return 0;
        }
    }
    $self->_error( 'Unknown META specification' );
    return 0;
}

sub anything { return 1 }

sub string {
    my ($self,$key,$value) = @_;
    if(defined $value) {
        return 1    if($value || $value =~ /^0$/);
    }
    $self->_error( "value is an undefined string" );
    return 0;
}

sub string_or_undef {
    my ($self,$key,$value) = @_;
    return 1    unless(defined $value);
    return 1    if($value || $value =~ /^0$/);
    $self->_error( "No string defined for '$key'" );
    return 0;
}

sub file {
    my ($self,$key,$value) = @_;
    return 1    if(defined $value);
    $self->_error( "No file defined for '$key'" );
    return 0;
}

sub exversion {
    my ($self,$key,$value) = @_;
    if(defined $value && ($value || $value =~ /0/)) {
        my $pass = 1;
        for my $val (split ',', $value) {
            unless (defined $val && (
                $val eq '0' || eval { SemVer->new($val) }
            )) {
                $self->_error( "'$val' for '$key' is not a valid version." );
                $pass = 0;
            }
        }
        return $pass;
    }
    $value = '<undef>'  unless(defined $value);
    $self->_error( "'$value' for '$key' is not a valid version." );
    return 0;
}

sub version {
    my ($self,$key,$value) = @_;
    if (defined $value) {
        return 1    if eval { SemVer->new($value) };
    } else {
        $value = '<undef>';
    }
    $self->_error( "'$value' for '$key' is not a valid version." );
    return 0;
}

sub boolean {
    my ($self,$key,$value) = @_;
    if(defined $value) {
        return 1    if($value =~ /^(0|1|true|false)$/);
    } else {
        $value = '<undef>';
    }
    $self->_error( "'$value' for '$key' is not a boolean value." );
    return 0;
}

my %licenses = map { $_ => 1 } qw(
    agpl_3
    apache_1_1
    apache_2_0
    artistic_1
    artistic_2
    bsd
    freebsd
    gfdl_1_2
    gfdl_1_3
    gpl_1
    gpl_2
    gpl_3
    lgpl_2_1
    lgpl_3_0
    mit
    mozilla_1_0
    mozilla_1_1
    openssl
    perl_5
    postgresql
    qpl_1_0
    ssleay
    sun
    zlib
    open_source
    restricted
    unrestricted
    unknown
);

sub license {
    my ($self,$key,$value) = @_;
    if(defined $value) {
        return 1    if($value && exists $licenses{$value});
    } else {
        $value = '<undef>';
    }
    $self->_error( "License '$value' is invalid" );
    return 0;
}

sub custom_1 {
    my ($self,$key) = @_;
    if(defined $key) {
        # a valid user defined key should be alphabetic
        # and contain at least one capital case letter.
        return 1    if($key && $key =~ /^[_a-z]+$/i && $key =~ /[A-Z]/);
    } else {
        $key = '<undef>';
    }
    $self->_error( "Custom resource '$key' must be in CamelCase." );
    return 0;
}

sub custom_2 {
    my ($self,$key) = @_;
    if(defined $key) {
        return 1    if($key && $key =~ /^x_/i);  # user defined
    } else {
        $key = '<undef>';
    }
    $self->_error( "Custom key '$key' must begin with 'x_' or 'X_'." );
    return 0;
}

sub identifier {
    my ($self,$key) = @_;
    if(defined $key) {
        return 1    if($key && $key =~ /^([a-z][_a-z]+)$/i);    # spec 2.0 defined
    } else {
        $key = '<undef>';
    }
    $self->_error( "Key '$key' is not a legal identifier." );
    return 0;
}

sub module {
    my ($self,$key) = @_;
    if(defined $key) {
        return 1    if($key && $key =~ /^[A-Za-z0-9_]+(::[A-Za-z0-9_]+)*$/);
    } else {
        $key = '<undef>';
    }
    $self->_error( "Key '$key' is not a legal module name." );
    return 0;
}

my @valid_phases = qw/ configure build test runtime develop /;
sub phase {
    my ($self,$key) = @_;
    if(defined $key) {
        return 1 if( length $key && grep { $key eq $_ } @valid_phases );
        return 1 if $key =~ /x_/i;
    } else {
        $key = '<undef>';
    }
    $self->_error( "Key '$key' is not a legal phase." );
    return 0;
}

my @valid_relations = qw/ requires recommends suggests conflicts /;
sub relation {
    my ($self,$key) = @_;
    if(defined $key) {
        return 1 if( length $key && grep { $key eq $_ } @valid_relations );
        return 1 if $key =~ /x_/i;
    } else {
        $key = '<undef>';
    }
    $self->_error( "Key '$key' is not a legal prereq relationship." );
    return 0;
}

sub _error {
    my $self = shift;
    my $mess = shift;

    $mess .= ' ('.join(' -> ',@{$self->{stack}}).')'  if($self->{stack});
    $mess .= " [Validation: $self->{spec}]";

    push @{$self->{errors}}, $mess;
}

1;

__END__

=head1 Support

This module is stored in an open L<GitHub
repository|http://github.com/theory/pgxn-meta/>. Feel free to fork and
contribute!

Please file bug reports via L<GitHub
Issues|http://github.com/theory/pgxn-meta/issues/> or by sending mail to
L<bug-PGXN-Meta@rt.cpan.org|mailto:bug-PGXN-Meta@rt.cpan.org>.

=cut