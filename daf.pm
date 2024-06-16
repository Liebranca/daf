#!/usr/bin/perl
# ---   *   ---   *   ---
# DAF
# Archiver of darkness
#
# LIBRE SOFTWARE
# Licensed under GNU GPL3
# be a bro and inherit
#
# CONTRIBUTORS
# lyeb,

# ---   *   ---   *   ---
# deps

package daf;

  use v5.36.0;
  use strict;
  use warnings;

  use Carp;
  use English qw(-no_match_vars);

  use lib "$ENV{ARPATH}/lib/sys/";

  use Style;
  use Chk;

  use Type;
  use Type::cstr;

  use Bpack;

  use Arstd::Path;
  use Arstd::Int;
  use Arstd::Bytes qw(bitscanf bitscanr);
  use Arstd::IO;
  use Arstd::WLog;
  use Arstd::xd;

  use parent 'St';

# ---   *   ---   *   ---
# info

  our $VERSION = v0.00.9;#a
  our $AUTHOR  = 'IBN-3DILA';

# ---   *   ---   *   ---
# ROM

St::vconst {


  DEFAULT => {
    blk_sz  => 0,

  },


  ext    => '.daf',
  sig    => 0xF0DA,

  tab_t  => sub {

    my $class=$_[0];
    my $struc=struc "$class.tab_t" => q[
      word ezy;

    ];

    return $struc;

  },

  head_t => sub {

    my $class=$_[0];
    my $struc=struc "$class.head_t" => q[

      word  sig;
      word  blk_sz;

      word  cnt;
      word  blkcnt;

    ];

    return $struc;

  },


  freeblk    => "\x{7F}\$S",
  freeblk_re => sub {

    my $class = $_[0];
    my $s     = $class->freeblk;

    return qr{^$s$};

  },

  dumpstep    => 0x1000,
  hash_loc_sz => (typefet 'word'),

};

# ---   *   ---   *   ---
# get path to tmp file

sub ftmp($self,$idex=0) {

  my $path=
    $self->{path}
  . $self->ext
  . 'body';

  $path .= $idex if $idex;
  return $path;

};

# ---   *   ---   *   ---
# make ice

sub new($class,$path,%O) {


  # set defaults
  $class->defnit(\%O);

  # make ice
  my $self=bless {

    path   => $path,
    cnt    => 0,
    blkcnt => 0,

    fh     => undef,
    tab    => {mask=>[],size=>0,step=>0},

    blk_sz => $O{blk_sz},

    update => {rehash=>0,defrag=>0},

  },$class;


  # remember unscaled block size?
  if(! $O{open}) {

    $self->{blk_sz_src}=
      $self->{blk_sz};

    $self->{blk_sz}=
      1 << ($self->{blk_sz}+4);

  };


  return $self;

};

# ---   *   ---   *   ---
# make new archive

sub fnew($class,$path,%O) {


  # get ice
  my $self   = $class->new($path,%O);
  my $head_t = $self->head_t;


  # make file
  open $self->{fh},'+>',$path . $self->ext
  or croak strerr($path);

  # ^put blank header
  print {$self->{fh}} (pack $head_t->{packof},

    $self->sig,
    $self->{blk_sz_src},
    $self->{cnt},
    $self->{blkcnt},

  );

  return $self;

};

# ---   *   ---   *   ---
# ^read existing

sub fopen($class,$path,%O) {


  # get ice
  my $self=$class->new($path,%O);

  # get content
  open $self->{fh},'+<',
    $self->{path} . $self->ext

  or croak strerr($path);


  # read header
  my $head_t = $self->head_t;
  my $head   = undef;

  read $self->{fh},
    $head,$head_t->{sizeof};


  # ^unpack and copy to memory
  my $have=bunpack $head_t,\$head;
     $have=$have->{ct}->[0];

  $self->{cnt}        = $have->{cnt};
  $self->{blkcnt}     = $have->{blkcnt};
  $self->{blk_sz_src} = $have->{blk_sz};

  $self->{blk_sz}     =
    1 << ($have->{blk_sz}+4);


  return $self;

};

# ---   *   ---   *   ---
# terminate edit

sub fclose($self) {


  # get ctx
  my $fh  = $self->{fh};
  my $dst = $self->{path} . $self->ext;

  # handle updates
  $self->defrag
  if $self->{update}->{defrag};

  $self->full_rehash
  if $self->{update}->{rehash};


  # rewind to header
  seek $fh,0,0;
  my $head_t=$self->head_t;

  # ^put data
  print {$fh} (pack $head_t->{packof},

    $self->sig,
    $self->{blk_sz_src},
    $self->{cnt},
    $self->{blkcnt},

  );


  # close file and give
  close $fh;
  return;

};

# ---   *   ---   *   ---
# load element at cursor
# into memory

sub read_elem($self) {


  # get ctx
  my $fh     = $self->{fh};
  my $blk_sz = $self->{blk_sz};
  my $tab_t  = $self->tab_t;

  my $loc    = tell $fh;


  # catch EOF
  my $chunk = null;
  my $have  = read $fh,$chunk,$blk_sz;

  return undef if ! $have;


  # get element size
  my $elem=substr $chunk,0,$tab_t->{sizeof},null;
     $elem=bunpack $tab_t,\$elem;

  $elem         = $elem->{ct}->[0];

  $elem->{path} = null;
  $elem->{base} = $loc;
  $elem->{loc}  = $loc + $tab_t->{sizeof} + 1;


  # get element path
  my $len=cstrlen \$chunk;

  $elem->{path} .= substr $chunk,0,$len;
  $elem->{loc}  += $len;

  # done?
  return $elem
  if $len < $blk_sz - $tab_t->{sizeof};


  # ^nope, read more blocks!
  while(read $fh,$chunk,$blk_sz) {

    my $len=cstrlen \$chunk;

    $elem->{path} .= substr $chunk,0,$len;
    $elem->{loc}  += $len;

    last if $len < $blk_sz;

  };


  return $elem;

};

# ---   *   ---   *   ---
# seek to begging of file,
# skipping header

sub rewind($self) {

  my $head_t=$self->head_t;
  seek $self->{fh},$head_t->{sizeof},0;

  return;

};

# ---   *   ---   *   ---
# seek to beggining of element

sub seek_this_elem($self,$elem) {
  return seek $self->{fh},$elem->{base},0;

};

# ---   *   ---   *   ---
# seek to beggining of next element

sub seek_next_elem($self,$from) {

  # get ctx
  my $blk_sz = $self->{blk_sz};
  my $base   = $from->{base};

  # get offset and seek
  $base += ($from->{ezy}+1) * $blk_sz;

  return seek $self->{fh},$base,0;

};

# ---   *   ---   *   ---
# look for path in table

sub fetch($self,$pathref) {


  # file in cache?
  return $self->{cache}->{$$pathref}
  if exists $self->{cache}->{$$pathref};


  # get ctx
  my $blk_sz = $self->{blk_sz};
  my $cnt    = $self->{cnt};

  my $i      = 0;
  my $out    = undef;

  $self->rewind();


  # walk table
  while($i++ < $cnt) {

    my $elem=$self->read_elem();


    # found requested?
    if($elem->{path} eq $$pathref) {
      $out=$elem;
      last;

    };


    # ^nope, go next
    $self->seek_next_elem($elem);

  };


  return $out;

};

# ---   *   ---   *   ---
# align and zero-pad input data

sub pack_data($self,$type,$data,$pathref) {


  # get ctx
  my $blk_sz = $self->{blk_sz};
  my $tab_t  = $self->tab_t;


  # combine tab, path and data
  my $path = bpack cstr=>$$pathref;
  my $have = bpack $type,@$data;


  $have->{ct}=
    $path->{ct}
  . $have->{ct};


  # get required/aligned size
  my $req    = $tab_t->{sizeof}+length $have->{ct};
  my $ezy    = int_urdiv $req,$blk_sz;

  my $total  = $ezy * $blk_sz;

  # ^record size!
  my $tab = Bpack::layas $tab_t,$ezy-1;
     $tab = bpack $tab_t => $tab;

  $have->{ct}=
    $tab->{ct}
  . $have->{ct};

  my $dataref=\$have->{ct};


  # ^zero-pad
  my $diff   = $total-$req;
  $$dataref .= pack "x[$diff]";


  # pack and give!
  return {

    bytes => $dataref,

    ezy   => $ezy,
    total => $total,

  };

};

# ---   *   ---   *   ---
# write element at end of file

sub new_elem($self,$data) {

  $self->seek_hash();
  print {$self->{fh}} ${$data->{bytes}};

  $self->{cnt}++;
  $self->{blkcnt} += $data->{ezy};

  $self->{update}->{rehash} |= 1;

  return;

};

# ---   *   ---   *   ---
# ^write to specific element

sub update_elem($self,$lkup,$data) {
  $self->seek_this_elem($lkup);
  print {$self->{fh}} ${$data->{bytes}};

  return;

};

# ---   *   ---   *   ---
# write element to another file

sub dump_elem($self,$dst,$lkup) {


  # get ctx
  my $step   = $self->dumpstep;
  my $blk_sz = $self->{blk_sz};
  my $total  = ($lkup->{ezy}+1) * $blk_sz;

  my $chunk  = null;


  # write content in chunks until end
  $self->seek_this_elem($lkup);

  while($total) {

    $step=$total if $step > $total;

    read  $self->{fh},$chunk,$step;
    print {$dst} $chunk;

    $total -= $step;

  };


  return;

};

# ---   *   ---   *   ---
# chunked flood-fill N bytes

sub flood($self,$data,$size) {


  # get ctx
  my $step = $self->dumpstep;


  # write content in chunks until end
  $data=pack 'Q',$data;

  while($size) {
    $step=$size if $step > $size;
    print {$self->{fh}} $data x $step;

    $size -= $step;

  };


  return;

};

# ---   *   ---   *   ---
# split file at element

sub cut($self,$ptr,$size) {


  # get element position
  my $blk_sz = $self->{blk_sz};
  my $ezy    = int_urdiv $size,$blk_sz;

  # path to [dst => tmp]
  my $body = $self->{fh};
  my $tmp  = $self->ftmp(1);


  # copy left of element
  my @call=(

    'dd',

    "if=$body",
    "of=$tmp",

    "bs=$blk_sz",
    "skip=" . ($ptr+$ezy),

    "status=none",
    "count=" . ($self->{cnt}-$ptr),

  );

  system {$call[0]} @call;


  # remove left and seek to end
  truncate $self->{fh},$ptr * $blk_sz;
  seek     $self->{fh},0,2;


  return ($body,$tmp);

};

# ---   *   ---   *   ---
# pack, then update or make new

sub store($self,$path,$type,$data) {


  # pack data and find where to put it ;>
  my $have = $self->pack_data($type,$data,\$path);
  my $lkup = $self->alloc(\$path,$have->{ezy}-1);


  # making new entry?
  if(! defined $lkup) {
    $self->new_elem($have);

  # overwrite existing!
  } else {
    $self->update_elem($lkup,$have);

  };


  return $have->{total};

};

# ---   *   ---   *   ---
# mark entry as avail

sub free($self,$path) {


  # skip if not found
  my $lkup=(! is_hashref $path)
    ? $self->fetch(\$path)
    : $path
    ;

  return 0 if ! defined $lkup;


  # get ctx
  my $blk_sz  = $self->{blk_sz};
  my $tab_t   = $self->tab_t;

  my $freeblk = $self->freeblk;
  my $cstr    = typefet 'cstr';


  # we identify free entries by placing
  # a special value in the path ;>
  $lkup->{path}=$self->freeblk;

  # get length of identifier,
  # then calculate length of padding
  my $ezy  = ($lkup->{ezy}+1) * $blk_sz;
  my $diff = (

    $ezy-1

  - (length $freeblk)
  - $tab_t->{sizeof}

  );


  # we zero-flood content
  #
  # this is not strictly necessary,
  # but it'll likely make the file
  # compress better

  my $fmat =
    $tab_t->{packof}
  . $cstr->{packof}
  . "x[$diff]";


  # ^overwrite data
  $self->seek_this_elem($lkup);

  print {$self->{fh}} pack $fmat,
    $lkup->{ezy},
    $freeblk;


  $self->{update}->{defrag} |= 1;
  $self->{update}->{rehash} |= 1;

  return 1;

};

# ---   *   ---   *   ---
# find block matching path and size
#
# if none found, look for
# a free block matching size

sub alloc($self,$pathref,$ezy) {


  # get ctx
  my $freeblk = $self->freeblk;

  my $cnt     = $self->{cnt};
  my $i       = 0;

  $self->rewind();


  # walk table
  my $req   = undef;
  my $avail = undef;
  my $out   = undef;

  while($i++ < $cnt) {

    my $elem=$self->read_elem();


    # found requested?
    if($elem->{path} eq $$pathref) {

      $req=$elem;

      # stop if size matches ;>
      $out=$req if $elem->{ezy} eq $ezy;


    # ^found free block matching size?
    } elsif(
       $elem->{path} eq $freeblk
    && $elem->{ezy}  eq $ezy

    ) {

      $avail=$elem;

      # backup to this block if
      # requested doesn't fit!
      $out=$avail if defined $req;

    };

    last if defined $out;


    # ^nope, go next
    $self->seek_next_elem($elem);

  };


  $out //= $avail;
  return $out;

};

# ---   *   ---   *   ---
# eliminates free blocks

sub defrag($self) {


  # get ctx
  my $freeblk = $self->freeblk;
  my $head_t  = $self->head_t;
  my $tmp     = $self->ftmp(1);

  my $cnt     = $self->{cnt};
  my $i       = 0;


  # open tmp file
  open my $dst,'+>',$tmp
  or croak strerr($tmp);

  # ^put blank header
  print {$dst} (pack $head_t->{packof},
    0,0,0,0,

  );

  # reset header
  $self->{cnt}    = 0;
  $self->{blkcnt} = 0;

  $self->rewind();


  # walk file and discard unwanted
  while($i++ < $cnt) {

    my $elem=$self->read_elem();


    # non free block?
    if($elem->{path} ne $freeblk) {

      $self->dump_elem($dst,$elem);

      $self->{cnt}++;
      $self->{blkcnt} += $elem->{ezy}+1;

    };

    $self->seek_next_elem($elem);

  };


  # ^overwrite header
  seek  $dst,0,0;
  print {$dst} (pack $head_t->{packof},
    $self->sig,
    $self->{blk_sz_src},
    $self->{cnt},
    $self->{blkcnt},

  );


  # ^swap!
  close  $self->{fh};
  rename $tmp,$self->{path} . $self->ext;

  $self->{fh}=$dst;

  $self->{update}->{defrag} &= 0;
  $self->{update}->{rehash} |= 1;

  return;

};

# ---   *   ---   *   ---
# recalculate hash table size

sub hash_step($self) {

  my $step  = int_npow2 $self->{cnt},1;
  my $limit = 1 << $step;

  while($limit < $self->{cnt}) {
    $step++;
    $limit=1 << $step;

  };


  $self->{tab}->{step} = $step;
  $self->{tab}->{size} = $limit;


  return;

};

# ---   *   ---   *   ---
# remove previous table

sub hash_clear($self) {


  # get ctx
  my $type=$self->hash_loc_sz;


  # get new size
  $self->hash_step();
  my $size=$self->{tab}->{size};


  # jump to table and zero-flood
  $self->seek_hash();
  $self->flood(0x00,$size * $type->{sizeof});

  # ^remove tail
  my $eof=tell $self->{fh};
  truncate $self->{fh},$eof;


  # remove previous mask
  $self->hash_reset_mask();

  return;

};

# ---   *   ---   *   ---
# ^reset table avail masks

sub hash_reset_mask($self) {


  # get ctx
  my $size=$self->{tab}->{size};


  # build blank array
  my @ar=(
    map {0x00}
    0..(int_urdiv $size,64)-1

  );


  # ^make two copies
  $self->{tab}->{fetch_mask} = [@ar];
  $self->{tab}->{avail_mask} = [@ar];


  return;

};

# ---   *   ---   *   ---
# make hash key from path

sub hash_path($self,$path) {


  # get ctx
  my ($step,$limit)=(
    $self->{tab}->{step},
    $self->{tab}->{size},

  );


  # align path to qword
  my $have = length $path;

  my $ezy  = int_align $have,8;
  my $diff = $ezy-$have;

  $path .= "\x{00}" x $diff;


  # qword xmas!
  my $x=0x00;

  map {

    my $i    = 0;
    my $word = 0x00;

    map {

      $word |=
         (ord $ARG)
      << ($i++ * 8);

    } reverse split null,$ARG;

    $x ^= $word;

  } grep {
    length $ARG

  } split qr[(.{8})],$path;


  # iterative clamp
  my $mask   = $limit-1;
  my $upmask = ~$mask;

  while($x > $mask) {

    my $y=$x;

    $x  &= $mask;
    $y  &= $upmask;

    $y >>= $step;
    $x  ^= $y;

  };


  return $x;

};

# ---   *   ---   *   ---
# get [idex => bit] of hash key

sub get_hash_mask($self,$x) {

  my $idex = (int_urdiv $x,64)-1;
  my $bit  = 1 << ($x & 63);

  return ($idex,$bit);

};

# ---   *   ---   *   ---
# put ptr to element in table

sub rehash($self,$elem) {


  # get ctx
  my $skip  = $self->head_t->{sizeof};
  my $fmask = $self->{tab}->{fetch_mask};
  my $amask = $self->{tab}->{avail_mask};

  my $loc = $elem->{base}-$skip;
     $loc = int_urdiv $loc,$self->{blk_sz};


  # get free slot for element
  my ($idex,$bit)=
    hash_get_free($self,$elem,$fmask);

  # ^validate
  croak "unhashable '$elem->{path}'"
  if ! defined $idex;


  # jump to table entry
  my $old   = tell $self->{fh};
  my $coord = $bit+($idex*64);

  $self->seek_hash($coord);

  # overwrite loc
  my $type  = $self->hash_loc_sz;
  my $bytes = pack $type->{packof},$loc-1;

  print {$self->{fh}} $bytes;


  # mark occupied
  $fmask->[$idex] |= $bit;
  $amask->[$idex] |= $bit;

  # jump back and give
  seek $self->{fh},$old,0;

  return;

};

# ---   *   ---   *   ---
# ^entire table

sub full_rehash($self) {


  # get ctx
  my $cnt = $self->{cnt};
  my $i   = 0;


  # reset
  $self->hash_clear();
  $self->rewind();


  # walk file
  while($i++ < $cnt) {

    my $elem=$self->read_elem();


    # insert all elements!
    $self->rehash($elem);
    last if ! $self->seek_next_elem($elem);

  };


  $self->{update}->{rehash} &= 0;
  return;

};

# ---   *   ---   *   ---
# find coords of next free slot

sub hash_get_free($self,$elem,$mask) {


  # get key for path
  my $x=$self->hash_path($elem->{path});

  # ^check for collision
  my ($idex,$bit)=
    $self->get_hash_mask($x);

  my $start=$idex;


  # slot occupied?
  retry:

  my $bmask=\$mask->[$idex];
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
      $idex=0 if $idex >= int @$mask;

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

sub hash_get_occu($self,$pathref,$mask) {


  # get key for path
  my $x=$self->hash_path($$pathref);

  # ^check for collision
  my ($idex,$bit)=
    $self->get_hash_mask($x);

  my $start=$idex;


  # have correct slot?
  retry:

  my $bmask = \$mask->[$idex];
  my $coord = $bit+($idex*64);

  if($$bmask & $bit) {

    my $elem=$self->hash_hit($pathref,$coord);


    # slot doesn't match data?
    if(! defined $elem) {

      # try rellocating
      $idex++;
      $idex=0 if $idex >= int @$mask;

      # ^fail if array is full!
      goto retry if $idex != $start;
      return null;


    # ^fetched, stop
    } else {
      return $elem;

    };

  };


  return null;

};

# ---   *   ---   *   ---
# seek to hash table entry

sub seek_hash($self,$coord=0x00) {

  # get ctx
  my $type   = $self->hash_loc_sz;
  my $skip   = $self->head_t->{sizeof};

  my $blk_sz = $self->{blk_sz};
  my $break  = $self->{blkcnt} * $blk_sz;

  # jump to begging of table
  $break=$break+($coord * $type->{sizeof});
  return seek $self->{fh},$skip+$break,0;

};

# ---   *   ---   *   ---
# ensure hash key matches data

sub hash_hit($self,$pathref,$coord) {


  # get ctx
  my $type   = $self->hash_loc_sz;
  my $skip   = $self->head_t->{sizeof};

  my $blk_sz = $self->{blk_sz};


  # jump to begging of table
  my $old=tell $self->{fh};
  $self->seek_hash($coord);

  # get location of element
  my $loc=0x00;
  read $self->{fh},$loc,$type->{sizeof};

  $loc = unpack $type->{packof},$loc;
  $loc = ($loc+1) * $blk_sz;


  # jump to location and read elem
  seek $self->{fh},$skip+$loc,0;
  my $elem=$self->read_elem();

  # ^validate
  croak "bad hash: '$$pathref'"
  if ! defined $elem;


  # restore position!
  seek $self->{fh},$old,0;

  # check elem path against lookup
  # give elem if valid!
  return ($$pathref eq $elem->{path})
    ? $elem : null ;

};

# ---   *   ---   *   ---
# dbout

sub err($self,$me,%O) {

  $WLog   //= $WLog->genesis;
  $O{lvl} //= $AR_FATAL;

  my $class=(length ref $self)
    ? ref $self
    : $self
    ;

  $WLog->err($me,%O,from=>$class);

  return;

};

# ---   *   ---   *   ---
# the bit

use Arstd::xd;

my $pkg  = St::cpkg;
my $daf  = $pkg->fnew('./testy');

#use Shb7;
#
#my $tree = Shb7::walk(glob '~');
#my @fake = map {
#  $ARG->{value}
#
#} $tree->get_file_list(full_path=>0);

my @fake=qw(x0 x1 x2);

map {

  $daf->store(
    "$fake[$ARG]",
    'word',[(0x2420|$ARG) x 8]

  )

} 0..$#fake;


$daf->defrag();
$daf->full_rehash();

my $elem=$daf->hash_get_occu(
  \'x2',$daf->{tab}->{fetch_mask}

);

use Fmat;
fatdump \$elem;

$daf->fclose();

# TODO
#
# * subdirs

# ---   *   ---   *   ---
1; # ret
