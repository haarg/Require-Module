package Require::Module;
BEGIN {
  $^H = 0;
  ${^WARNING_BITS} = '';
}
BEGIN {
  if ($ENV{RELEASE_TESTING}) {
    require strict;
    strict->import;
    require warnings;
    warnings->import;
  }
}

our $VERSION = '0.001000';
$VERSION =~ tr/_//d;

our @EXPORT_OK = qw(
  $module_name_rx
  is_module_name
  check_module_name
  module_notional_filename
  require_module
  require_file
  use_module
  use_package_optimistically
  try_require_module
);
my %EXPORT_OK = map +($_ => 1), @EXPORT_OK;

sub import {
  shift;
  my $caller = caller;

  my @bad;
  for my $import (@_) {
    BEGIN { $ENV{RELEASE_TESTING} and strict->unimport('refs') }
    if (!exists $EXPORT_OK{$import}) {
      push @bad, $import;
      next;
    }
    elsif ($import =~ /\A\$(.*)/s) {
      *{"${caller}::$import"} = \${$1};
    }
    else {
      *{"${caller}::$import"} = \&$import;
    }
  }
  if (@bad) {
    die sprintf("%s at %s line %s.\n",
      join("\n",
        (map qq["$_" is not exported by the ].__PACKAGE__.qq[ module], @bad),
        q[Can't continue after import errors],
      ),
      (caller)[1,2],
    );
  }
}

our $module_name_rx = qr{
  (?=[^0-9':])
  (?:
    ::
  |
    \w*
    (?:'[^\W0-9]\w*)*
  )*
}x;

sub is_module_name ($) {
  defined $_[0] && $_[0] =~ /\A$module_name_rx\z/;
}

sub check_module_name ($) {
  if (!is_module_name($_[0])) {
    die sprintf "%s is not a module name", (defined $_[0] ? "'$_[0]'" : 'argument');
  }
}

sub module_notional_filename ($) {
  my $file = shift;
  check_module_name($file);
  $file =~ s{::|'}{/}g;
  return "$file.pm";
}


BEGIN {
  *_WORK_AROUND_HINT_LEAKAGE
    = "$]" < 5.011 && !("$]" >= 5.009004 && "$]" < 5.010001) ? sub(){1} : sub(){0};
  *_WORK_AROUND_BROKEN_MODULE_STATE
    = "$]" < 5.009 ? sub(){1} : sub(){0};
}

BEGIN {
  my $e;
  if(_WORK_AROUND_BROKEN_MODULE_STATE) {
    local $@;
    eval q{
      sub Require::Module::__GUARD__::DESTROY {
        delete @INC{@{$_[0]}};
      }
      1;
    } or die $e = $@;
  }
  die $e if defined $e;
}

sub require_file ($) {
  my $file = $_[0];

  # Localise %^H to work around [perl #68590], where the bug exists
  # and this is a satisfactory workaround.  The bug consists of
  # %^H state leaking into each required module, polluting the
  # module's lexical state.
  local %^H if _WORK_AROUND_HINT_LEAKAGE;
  if (_WORK_AROUND_BROKEN_MODULE_STATE) {
    my $guard = bless [ $file ], 'Require::Module::__GUARD__';
    my $result = require $file;
    pop @$guard;
    return $result;
  }
  else {
    return scalar require $file;
  }
}

sub require_module ($) {
  require_file(module_notional_filename($_[0]));
}

sub use_module ($@) {
  my $module = shift;
  require_module($module);
  if (@_) {
    $module->VERSION(@_);
  }
  return $name;
}

sub use_package_optimistically ($@) {
  my $module = shift;
  my $file = module_notional_filename($module);
  if (
    ! eval { require_module($name); 1 } && (
      $@ !~ /\ACan't locate \Q$file\E /
    ||
      $@ =~ /\A^Compilation\ failed\ in\ require /
    )
  ) {
    die $@;
  }
  if (@_) {
    $module->VERSION(@_);
  }
  return $name;
}

# XXX provide error in $@ ?  include version check?
sub try_require_module ($@) {
  my $module = shift;
  my $file = module_notional_filename($module);
  my $e;
  {
    local $@;
    eval { require_module($name); 1 } or $e = $@;
  }
  if (
    defined $e && (
      $e !~ /\ACan't locate \Q$file\E /
    ||
      $e =~ /\A^Compilation\ failed\ in\ require /
    )
  ) {
    die $e;
  }
  if (@_) {
    local $@;
    eval { $module->VERSION(@_); 1 } or return !!0;
  }
  return !defined $e;
}

1;
__END__

=head1 NAME

Require::Module - Load modules by name

=head1 SYNOPSIS

  use Require::Module qw(require_module);

  require_module "My::Module";

=head1 DESCRIPTION

This module will load modules by their name, specified as a string.

This module is modeled after L<Module::Runtime> but aims to fix various issues
with that module. It is meant to be compatible with 99% of uses of
L<Module::Runtime>.

=head1 EXPORTS

=head2 $module_name_rx

=head2 is_module_name

=head2 check_module_name

=head2 module_notional_filename

=head2 require_module

=head2 require_file

=head2 use_module

=head2 use_package_optimistically

=head2 try_require_module

Try to load the module given, and return a true or false value based on if it
succeeded or failed. If there is a compilation failure while loading the module,
it will be thrown.

=head1 WHY Require::Module

Why should Require::Module be used rather than one of the 500 other module
loaders on CPAN?

=over 4

=item * Works around differences in older perl releases

If a module is loaded on perl 5.8 and it fails to compile, future attempts to
load the module will return true without error. This module works around this
issue.

=item * Loads no modules

This module doesn't load any other modules, not even strict or warnings. This
means it can be used in any situation.

=back

=head2 Comparison with Module::Runtime

Module::Runtime is already widely used, and it solves the problems listed above.
Why not use the established solution?

=over 4

=item * No non-core prerequisites

This module has no prerequisites that don't ship with perl 5.8. This is a
with Module::Runtime.

=item * Doesn't interfere with core hooks

Core hooks that use CORE::GLOBAL::require or C<$SIG{__DIE__}> can modify the
error messages that need to be checked by the use_package_optimistically and
try_require_module functions. However, we trust that anyone writing these hooks
will be responsible and won't modify the errors too much. Module::Runtime tries
to avoid these hooks, which while more reliable, prevents the hooks from doing
their useful work.

=item * Allows Unicode module names

Mapping Unicode module names to file systems, especially across operating
systems, is not fully consistent.  However, perl itself allows these to be used,
so we allow them to be used.

=item * Allow C<'> package separators

Similar to Unicode names, since perl itself allows single quotes to be used as
package separators, we don't prevent them from being used with this module.

=item * More friendly prototypes

Module::Runtime uses prototypes like C<($;$)>, which forces scalar context on
its optional parameters. This makes it hard to conditionally provide the
additional parameter. We avoid this by using C<($@)> prototypes in those cases.

=item * More useful optional module loading

While the L</use_package_optimistically> function is provided for compatibility,
its behavior rarely seems to be what people want. C<use_package_optimistically>
returns the module name for missing or existing modules, as long as there wasn't
a compilation error. To detect if the module was actually loaded, which seems
to be the most commonly desired behavior, requires an additional check. The
L</try_require_module> function returns a true or false value to make this
easier.

=item * Removed unused functions

Module::Runtime provides functions for combining partial module names, using
C</> a separator or to indicate if a prefix should be added. This form of
composition has barely seen any use in the real world, in favor of other forms.
Such an uncommonly used mechanism doesn't seem to belong in a module meant to
be used like this one.

=back

=head1 SEE ALSO

=over 4

=item L<Module::Runtime>

=item L<Module::Load>

=item L<Module::Use>

=item L<Module::Loader>

=item L<Module::Require>

=item L<UNIVERSAL::Require>

=back

=head1 AUTHOR

haarg - Graham Knop (cpan:HAARG) <haarg@haarg.org>

=head1 CONTRIBUTORS

None so far.

=head1 COPYRIGHT

Copyright (c) 2020 the Require::Module L</AUTHOR> and L</CONTRIBUTORS>
as listed above.

=head1 LICENSE

This library is free software and may be distributed under the same terms
as perl itself. See L<https://dev.perl.org/licenses/>.

=cut
