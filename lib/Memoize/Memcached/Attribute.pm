package Memoize::Memcached::Attribute;

use strict;
use warnings;

use Sub::Attribute;

use Digest::MD5 ();
use Storable ();

our $VERSION = '0.10'; # VERSION
our $MEMCACHE;

sub import {
	my $package = shift;
	my %attrs   = (UNIVERSAL::isa($_[0], 'HASH')) ? %{ $_[0] } : @_;


	unless ($attrs{'-noattrimport'}) {
		my ($caller) = caller();
		no strict 'refs';
		*{ "$caller\::CacheMemoize" } = \&CacheMemoize;
		*{ "$caller\::MODIFY_CODE_ATTRIBUTES" } = \&MODIFY_CODE_ATTRIBUTES;
	}

	delete $attrs{'-noattrimport'};

	if ($attrs{'-client'}) {
		$MEMCACHE = $attrs{'-client'};
	}
	else {
		client(%attrs);
	}
}

sub client {
	my %params = @_;
	return $MEMCACHE ||= do {
		my $memcache_pkg;
		eval {
			require Cache::Memcached::Fast;
			$memcache_pkg = 'Cache::Memcached::Fast';
		};
		if ($@) {
			require Cache::Memcached;
			$memcache_pkg = 'Cache::Memcached';
		}
		$memcache_pkg->new(\%params);
	};
}

sub CacheMemoize :ATTR_SUB {
	my ($package, $symbol, $referent, $attr, $params) = @_;

	no strict 'refs';

	$params = _parse_attr_params($params);

	my $is_method   = 0;
	if (@$params > 1) {
		my $type   = shift @$params;
		$is_method = 1 if (lc($type) eq 'method');
	}

	my $duration    = $params->[0];

	my $symbol_name = join('::', $package, *{ $symbol }{NAME});

	no warnings 'redefine';
	my $original = \&{ $symbol_name };
	*{$symbol_name} = sub {
		my @args   = @_;

		# if we're in a method, don't use the object to build the key
		my @key_args = @args;
		shift @key_args if ($is_method);

		my $key = _build_key($symbol_name, @key_args);

		if (wantarray) {
			$key .= '-wantarray';
			my $ref = $MEMCACHE->get($key) || do {
				my @list = $original->(@args);
				$MEMCACHE->set($key, \@list, $duration) if (@list);
				\@list;
			};
			return @$ref;
		}



		my $cached = $MEMCACHE->get($key);
		return $cached if (defined $cached);

		my $result = $original->(@args);
		$MEMCACHE->set($key, $result, $duration) if (defined $result);
		return $result;
	};
}

sub invalidate {
	my $symbol_name = shift;
	if ($symbol_name !~ /::/) {
		# build the full method from the caller's namespace if necessary
		$symbol_name = join('::', (caller)[0], $symbol_name);
	}

	my $key = Memoize::Memcached::Attribute::_build_key($symbol_name, @_);
	$MEMCACHE->delete($key);
	$MEMCACHE->delete("${key}-wantarray");
}

sub _parse_attr_params {
	my ($string) = @_;

	return [] unless defined $string;

	my $data = eval "
		no warnings;
		no strict;
		[$string]
	";

	return $data || [$string];
}

sub _build_key {
	local $Storable::canonical = 1;
	return Digest::MD5::md5_base64(Storable::nfreeze(\@_));
}

1;
__END__

=head1 NAME

Memoize::Memcached::Attribute - auto-memoize function results using memcached

=head1 VERSION

version 0.10

=head1 SYNOPSIS

To set up your memcache client for this package, you can pass the params in during import:

	use Memoize::Memcached::Attribute (servers => [ '127.0.0.1:11211' ]);

Alternatively, you can pass in your memcache client object entirely (we use this because
we subclass Cache::Memcached::Fast to add some additional methods and default parameters):

	use Memoize::Memcached::Attribute (-client => Cache::Memcached::Fast->new({ servers => [ '127.0.0.1:11211' ] }));

Or you can specify it at runtime, the only caveat being that you must do this prior to calling any memoized function:

	use Memoize::Memcache::Attribute;
	Memoize::Memcache::Attribute::client(Cache::Memcached::Fast->new({ servers => [ '127.0.0.1:11211' ] }));

To use the memoization, you use the :CacheMemoize subroutine attribute, which takes a cache duration as a parameter:

	# cache the results in memcache for 5 minutes
	sub myfunc :CacheMemoize(300) {
		my @params = @_;
		my $total;
		$total += $_ for @params;
		return $total;
	}

Sometimes you have a method that is not dependent on object state, and you want to memoize those results,
independent of the object used to generate them:

	# cache the results in memcache for 30 seconds
	# but don't look at the object as part of the input data
	sub mymethod :CacheMemoize(method => 30) {
		my $self = shift;
		my @params = @_;
		return join('.', @params);
	}

While not generally recommended as good design, we do support the ability to
invalidate caches.  If you find yourself using the invalidation often, this module
is probably not really how you want to go about achieving your caching strategy.
Here's how you do it:

	Memoize::Memcached::Attribute::invalidate('Some::Package::myfunc', @params);

If you're invalidating the cache from inside the same package as the cached function (which
is probably the only place you should be), you can omit the package name:

	Memoize::Memcached::Attribute::invalidate('mymethod', @params);



=head1 DESCRIPTION

Memoization is a process whereby you cache the results of a function, based on its input,
in memory.  This module expands that concept to use memcache to provide a shared memory
cache rather than a per-process cache like a lot of other memoization modules.  You can
also specify a timeout, in case your results might change, just not that frequently.

=head1 OPTIONS

When you import the package, you can pass a few options in:

=over4

=item -noattrimport - Precludes importing the necessary methods to the calling namespace

=item -client - Allows you to specify your own memcache client object.  Useful if you subclass
Cache::Memcached in your codebase.

=back

Any remaining options will be used to connect to the Cache::Memcached client object, if passed.

=head1 THREADS/FORKING

Because this module internally stores the memcached client as a package global, and the memcached clients
have issues with threads and forking, it would be wise to reset the package global after forking or creating
a new thread.  This can be done like this:

	if (my $pid = fork) {
		# parent
	}
	else {
		Memoize::Memcached::Attribute::client(%client_constructor_params);
		# or $Memoize::Memcached::Attribute::MEMCACHE = $memcached_client_object;
	}

=head1 ACKNOWLEDGEMENTS

Thanks to Chris Reinhardt and David Dierauer for finding and fixing some issues.  And to
LiquidWeb for allowing me to contribute this to CPAN.

=head1 BUGS

None known.  This has been in use in LiquidWeb production code for a few years without any known issues.

If you find one, or have a feature request, submit them here:
https://github.com/jimbobhickville/perl-Memoize-Memcached-Attribute/issues/new

=head1 LICENCE

Copyright 2010-2012, Greg Hill (jimbobhickville -AT- gmail -DOT- com)

This software is free.  It is licensed under the same terms as Perl itself.

The latest version of this software should be available from my github repo:
https://github.com/jimbobhickville/perl-Memoize-Memcached-Attribute

=cut
