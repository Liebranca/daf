#!/usr/bin/perl

# ---   *   ---   *   ---
# deps

  use v5.36.0;
  use strict;
  use warnings;

  use lib $ENV{'ARPATH'}.'/lib/';
  use Avt;

# ---   *   ---   *   ---
# the bit

Avt::set_config(
  name => 'daf',

);

Avt::scan();
Avt::config();
Avt::make();

# ---   *   ---   *   ---
1; # ret
