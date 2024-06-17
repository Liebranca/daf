#!/usr/bin/perl
# ---   *   ---   *   ---
# DAF HASH
# Finder of tomes
#
# LIBRE SOFTWARE
# Licensed under GNU GPL3
# be a bro and inherit
#
# CONTRIBUTORS
# lyeb,

# ---   *   ---   *   ---
# deps

package daf::hash;

  use v5.36.0;
  use strict;
  use warnings;

  use Carp;
  use English qw(-no_match_vars);

  use lib "$ENV{ARPATH}/lib/sys/";

  use Style;
  use Type;
  use Bpack qw(bpack bunpack);

  use Arstd::Int;
  use Arstd::Bytes qw(bitscanf bitscanr);

  use parent 'St';

# ---   *   ---   *   ---
# info

  our $VERSION = v0.00.2;#a
  our $AUTHOR  = 'IBN-3DILA';

# ---   *   ---   *   ---
# ROM

St::vconst {
  loc_sz => (typefet 'word'),

};

# ---   *   ---   *   ---
# cstruc

sub new($class,%O) {


  # validate
  return null
  if ! defined $O{main};


  # make ice and give
  my $self=bless {

    main  => $O{main},

    step  => 0,
    size  => 0,

    fetch => [],
    avail => [],

    fetch_mask => [],
    avail_mask => [],

  },$class;


  $self->clear($O{size});
  return $self;

};

# ---   *   ---   *   ---
# recalculate hash table size

sub recalc_step($self,$cnt) {


  # zero would break this F ;>
  $cnt = 1 if ! $cnt;


  # find closest power of 2 to
  # specified element count
  my $step  = int_npow2 $cnt,1;
  my $limit = 1 << $step;

  # ^ensure we got it right ;>
  while($limit < $cnt) {
    $step++;
    $limit=1 << $step;

  };


  # calc mask array size
  my $mask_sz=(int_urdiv $limit,64);


  # save results and give
  $self->{step} = $step;
  $self->{size} = $limit;

  $self->{mask_size} = $mask_sz;

  return;

};

# ---   *   ---   *   ---
# remove previous table

sub clear($self,$cnt) {


  # get new size
  $self->recalc_step($cnt);
  my $size=$self->{size};

  # zero-out the cache
  $self->{fetch}=[(0x0000) x $size];
  $self->{avail}=[];

  # remove previous mask
  $self->reset_mask();


  # schedule rehash
  my $main=$self->{main};
  $main->{update}->{rehash} |= 1;

  return;

};

# ---   *   ---   *   ---
# ^reset table avail masks

sub reset_mask($self) {

  # get ctx
  my $size=$self->{mask_size};

  # build blank array
  my @ar=map {0x00} 0..$size-1;

  # ^make two copies
  $self->{fetch_mask} = [@ar];
  $self->{avail_mask} = [@ar];

  return;

};

# ---   *   ---   *   ---
# make hash key from string

sub hash($self,$s) {


  # get ctx
  my ($step,$limit)=(
    $self->{step},
    $self->{size},

  );


  # align path to qword
  my $have = length $s;

  my $ezy  = int_align $have,8;
  my $diff = $ezy-$have;

  $s .= "\x{00}" x $diff;


  # make initial key
  my $x=0x00;

  map {

    my $i    = 0;
    my $word = 0x00;


    # combine bytes into single
    map {

      $word |=
         (ord $ARG)
      << ($i++ * 8);

    } reverse split null,$ARG;

    # ^then xor qwords together
    $x ^= $word;


  # ^break string into 8-byte chunks
  } grep {
    length $ARG

  } split qr[(.{8})],$s;


  # iterative clamp
  my $mask   = $limit-1;
  my $upmask = ~$mask;

  while($x > $mask) {

    my $y=$x;


    # get lower (in range)
    # and upper (out of range) portions
    $x  &= $mask;
    $y  &= $upmask;


    # ^then shift upper and xor with lower
    #
    # after N iterations, this gives us
    # a key that's in range without having
    # to apply division or discard bits

    $y >>= $step;
    $x  ^= $y;

  };


  return $x;

};

# ---   *   ---   *   ---
# get [idex => bit] of hash key

sub get_coord($self,$x) {

  my $idex = (int_urdiv $x,64);
  my $bit  = 1 << ($x & 63);

  $idex-- if $idex;

  return ($idex,$bit);

};

# ---   *   ---   *   ---
# put ptr to element in table

sub rehash($self,$elem) {


  # get ctx
  my $main  = $self->{main};
  my $skip  = $main->head_t->{sizeof};
  my $fmask = $self->{fetch_mask};
  my $amask = $self->{avail_mask};


  # get element location in blocks
  my $loc = $elem->{base}-$skip;
     $loc = int_urdiv $loc,$main->{blk_sz};

  $loc-- if $loc;

  # get next slot to store element
  my ($idex,$bit)=$self->get_slot(
    \$elem->{path}

  );

  # ^validate
  $main->err(
    "unhashable '%s'",
    args=>[$elem->{path}],

  ) if ! defined $idex;


  # overwrite cached value
  my $have  = bitscanf $bit;
  my $coord = $have+($idex*64);

  $self->{fetch}->[$coord]=$loc;


  # mark occupied
  $fmask->[$idex] |= $bit;
  $amask->[$idex] |= $bit;


  return;

};

# ---   *   ---   *   ---
# ^entire table

sub full_rehash($self) {


  # get ctx
  my $main = $self->{main};
  my $cnt  = $main->{cnt};
  my $i    = 0;


  # reset
  $self->clear($main->{cnt});
  $main->rewind();


  # walk file
  while($i++ < $cnt) {

    my $elem=$main->read_elem();


    # insert all elements!
    $self->rehash($elem);
    $main->seek_next_elem($elem);

  };


  $main->{update}->{rehash} &= 0;
  return;

};

# ---   *   ---   *   ---
# find free [idex => bit] for path

sub get_slot($self,$pathref) {
  my $x=$self->hash($$pathref);
  return $self->get_free($x,$pathref);

};

# ---   *   ---   *   ---
# find coords of any free slot

sub get_free($self,$x,$pathref=undef) {


  # get ctx
  my $fmask=$self->{fetch_mask};
  my $amask=$self->{avail_mask};


  # get slot coords
  my ($idex,$bit) = $self->get_coord($x);
  my $start       = $idex;


  # slot occupied?
  retry:

  my $bmask = \$amask->[$idex];
  my $smask = $fmask->[$idex];


  # if a path is provided,
  # then check that it matches
  #
  # on match, simply return these coords!

  if(defined $pathref && ($smask & $bit)) {

    my $have  = bitscanf $bit;

    my $coord = $have + ($idex * 64);
    my $elem  = $self->hit($pathref,$coord);

    return ($idex,$bit)
    if length $elem;

  };


  # ^move to next slot!
  if($$bmask & $bit) {


    # find next zero bit to the right
    my $nbmask = ~($$bmask);
    my $have   = bitscanf $nbmask;

    # ^to the left on fail!
    $have=bitscanr $nbmask
    if ! defined $have;

    $bit=1 << ($have-1)
    if defined $have;


    # neither side is free?
    if(! defined $have
    || ($bit & $$bmask)) {


      # try rellocating
      $idex++;
      $idex=0 if $idex >= int @$amask;

      # ^fail if array is full!
      goto retry if $idex != $start;
      return undef;


    # found avail, stop
    } else {
      $bit=1 << $have;

    };


  };


  return ($idex,$bit);

};

# ---   *   ---   *   ---
# ^read loc stored at path

sub get_occu($self,$pathref) {


  # get ctx
  my $mask=$self->{fetch_mask};


  # get key for path
  my $x=$self->hash($$pathref);

  # ^check for collision
  my ($idex,$bit) = $self->get_coord($x);

  my $start       = $idex;
  my $round       = 0;


  # have correct slot?
  retry:

  my $bmask = \$mask->[$idex];
  my $have  = bitscanf $bit;

  my $coord = $have+($idex*64);

  if($$bmask & $bit) {

    my $elem=$self->hit($pathref,$coord);


    # slot doesn't match data?
    if(! length $elem) {


      # try relloc on current mask?
      if($round < 64) {

        $bit=($bit < (1 << 63))
          ? $bit << 1
          : 1
          ;

        $round++;


      # ^relloc to next mask!
      } else {

        $round=0;

        $idex++;
        $idex=0 if $idex >= int @$mask;

        # ^fail if array is full!
        return null if $idex == $start;

      };


      goto retry;


    # ^fetched, stop
    } else {
      $elem->{hash_coord}=[$idex,$bit];
      return $elem;

    };

  };


  return null;

};

# ---   *   ---   *   ---
# find appropiate slot for value,
# matching path and size

sub alloc($self,$pathref,$ezy) {

  # get ctx
  my $main=$self->{main};

  # can find element?
  my $have=$self->get_occu($pathref);


  # element could not be found,
  # or element is not the right size!
  if(! (length $have)
  || ! ($have->{ezy} eq $ezy)) {


    # have free slot matching size?
    my $free=$self->{avail};

    if(defined $free->[$ezy]
    && int @{$free->[$ezy]}) {

      my $loc=pop @{$free->[$ezy]};
      seek $main->{fh},$loc,0;

      return $main->read_elem();


    # nope, time to add a new elem ;>
    } else {
      $main->free($have) if $have;
      return null;

    };


  # element found and has right size ;>
  } else {
    return $have;

  };

};

# ---   *   ---   *   ---
# clear element in table
#
# old cache/fetch values are kept
# so that the same path will still
# point to the same slot!

sub free($self,$elem) {


  # get ctx
  my ($idex,$bit)=
    @{$elem->{hash_coord}};

  my $coord = $bit + ($idex * 64);
  my $ezy   = $elem->{ezy};


  # put block in reuse queue
  my $dst=$self->{avail}->[$ezy] //= [];
  push @$dst,$elem->{base};

  # ^mark block as free!
  $self->{avail_mask} &= ~$bit;

  return;

};

# ---   *   ---   *   ---
# seek to hash table entry

sub seek_elem($self,$coord=0x00) {

  # get ctx
  my $main   = $self->{main};
  my $type   = $self->loc_sz;
  my $skip   = $main->head_t->{sizeof};

  my $blk_sz = $main->{blk_sz};
  my $break  = $main->{blkcnt} * $blk_sz;

  # jump to begging of table
  $break=$break+($coord * $type->{sizeof});
  return seek $main->{fh},$skip+$break,0;

};

# ---   *   ---   *   ---
# read table from file into memory

sub load($self) {


  # get ctx
  my $main  = $self->{main};
  my $type  = $self->loc_sz;
  my $cnt   = $main->{cnt};

  my $chunk = null;
  my $have  = null;

  $self->recalc_step($cnt);


  # jump to begging of table
  my $old=tell $main->{fh};
  $self->seek_elem(0);


  # read fetch mask
  read $main->{fh},$chunk,
    8 * $self->{mask_size};

  # ^unpack
  $have=bunpack qword=>\$chunk,0,
    $self->{mask_size};

  $self->{fetch_mask}=$have->{ct};


  # read N entries
  read $main->{fh},$chunk,
    $type->{sizeof} * $self->{size};

  # ^unpack
  $have=bunpack $type,\$chunk,0,
    $self->{size};

  $self->{fetch}=$have->{ct};


  # restore position and give
  seek $main->{fh},$old,0;
  $main->{update}->{rehash} &= 0;

  return;

};

# ---   *   ---   *   ---
# ^write in-memory table to
# the archive!

sub save($self) {

  # get ctx
  my $main  = $self->{main};
  my $type  = $self->loc_sz;
  my $cnt   = $main->{cnt};

  my $chunk = null;


  # jump to begging of table
  my $old=tell $main->{fh};
  $self->seek_elem(0);

  # discard previous
  my $eof=tell $main->{fh};
  truncate $main->{fh},$eof;


  # pack n dump mask array
  $chunk=bpack qword=>@{$self->{fetch_mask}};
  print {$main->{fh}} $chunk->{ct};

  # pack n dump entries
  $chunk=bpack $type,map {
    (defined $ARG) ? $ARG : 0x0000

  } @{$self->{fetch}};

  print {$main->{fh}} $chunk->{ct};


  # restore position and give
  seek $main->{fh},$old,0;

  return;

};

# ---   *   ---   *   ---
# ensure hash key matches data

sub hit($self,$pathref,$coord) {


  # get ctx
  my $main   = $self->{main};
  my $type   = $self->loc_sz;
  my $skip   = $main->head_t->{sizeof};

  my $blk_sz = $main->{blk_sz};


  # get location of element
  my $loc=$self->{fetch}->[$coord];
     $loc=($loc+1) * $blk_sz;


  # jump to location and read elem
  my $old=tell $main->{fh};

  seek $main->{fh},$skip+$loc,0;
  my $elem=$main->read_elem();

  # ^validate
  $main->err(
    "bad hash '%s'",
    args=>[$$pathref],

  ) if ! defined $elem;


  # restore position!
  seek $main->{fh},$old,0;

  # check elem path against lookup
  # give elem if valid!
  return ($$pathref eq $elem->{path})
    ? $elem : null ;

};

# ---   *   ---   *   ---
1; # ret
