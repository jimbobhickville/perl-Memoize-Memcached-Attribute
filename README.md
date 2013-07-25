perl-Memoize-Memcached-Attribute
================================

This module provides an easy way to do shared process memoization using memcached via subroutine attributes.  
It's a bit of an abuse of memoization as it is impermanent caching, but it makes it really simple to cache 
expensive calculated values on data that changes infrequently for a short period of time.

Documentation on how to use it can be found in the POD of the actual module here on github or on CPAN at
https://metacpan.org/module/Memoize::Memcached::Attribute
