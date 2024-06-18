#!/usr/bin/perl
# ---   *   ---   *   ---
# FILE
# Checks if my math is off
#
# TEST FILE
# jmp EOF for bits
#
# CONTRIBUTORS
# lyeb,

# ---   *   ---   *   ---
# deps

package main;

  use v5.36.0;
  use strict;
  use warnings;

  use Carp;
  use English qw(-no_match_vars);

  use lib "$ENV{ARPATH}/lib/sys";
  use Style;

  use Arstd::xd;
  use Fmat;

  use lib "$ENV{ARPATH}/lib/";
  use daf;

# ---   *   ---   *   ---
# test A

sub test_fnew($fname) {

  my $daf  = daf->fnew($fname);
  my @fake = qw(x0 x1 x2);

  map {

    $daf->store(
      "$fake[$ARG]",
      'word',[(0x2420|$ARG) x 8]

    )

  } 0..$#fake;

  $daf->fclose();
  return;

};

# ---   *   ---   *   ---
# test B

sub test_fopen($fname) {

  my $daf=daf->fopen($fname);

  $daf->store(x3=>word=>[(0x2424) x 8]);
  $daf->store(x4=>word=>[(0x4040) x 8]);


  my $have=$daf->fetch(\'x1');

  fatdump \$have;
  fatdump \$daf->{update};


  $have=$daf->read_data('x1');

  xd  $have,head=>0;
  say length $have;


  $daf->fclose();
  return;

};

# ---   *   ---   *   ---
# the bit

my $fname = './filetest';

test_fnew($fname);
test_fopen($fname);

unlink $fname . daf->ext;

# ---   *   ---   *   ---
1; # ret
