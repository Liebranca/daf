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
  use Type;
  use Bpack;

  use Arstd::Path;
  use Arstd::Int;
  use Arstd::IO;
  use Arstd::WLog;
  use Arstd::xd;

  use parent 'St';

# ---   *   ---   *   ---
# info

  our $VERSION = v0.00.4;#a
  our $AUTHOR  = 'IBN-3DILA';

# ---   *   ---   *   ---
# ROM

St::vconst {


  DEFAULT => {
    blk_sz  => 0,

  },


  ext    => '.daf',
  sig    => 0xAFBD,

  head_t => sub {

    my $class=$_[0];
    my $struc=struc "$class.head_t" => q[

      cstr path;

      word loc;
      word ezy;

    ];

    return $struc;

  },

  meta_t => sub {

    my $class=$_[0];
    my $struc=struc "$class.meta_t" => q[

      word  sig;
      word  blk_sz;

      word  cnt;
      word  blkcnt;
      qword break;

    ];

    return $struc;

  },

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

    head   => '',
    body   => undef,

    cache  => {},
    blk_sz => $O{blk_sz},

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
  my $self=$class->new($path,%O);

  # make tmp file
  open $self->{body},'+>',$self->ftmp
  or croak strerr($path);

  return $self;

};

# ---   *   ---   *   ---
# ^read existing

sub fopen($class,$path,%O) {


  # get ice
  my $self=$class->new($path,%O);

  # get content
  open $self->{body},'+<',
    $self->{path} . $self->ext

  or croak strerr($path);


  # read meta data
  my $meta_t = $self->meta_t;
  my $meta   = undef;

  read $self->{body},
    $meta,$meta_t->{sizeof};


  # ^unpack and copy to memory
  my $have=bunpack $meta_t,\$meta;
     $have=$have->{ct}->[0];

  $self->{break}      = $have->{break};
  $self->{cnt}        = $have->{cnt};
  $self->{blkcnt}     = $have->{blkcnt};
  $self->{blk_sz_src} = $have->{blk_sz};

  $self->{blk_sz}     =
    1 << ($have->{blk_sz}+4);


  # read header into memory
  read $self->{body},
    $self->{head},$self->{break};

  # put the remainder into tmp
  my $step = 0x1000;

  my $eof  = -s $self->{body};
  my $addr = tell $self->{body};

  open my $tmp,'+>',$self->ftmp;


  # ^one page at a time ;>
  while($addr < $eof) {

    my $chunk = null;
    my $left  = $eof-$addr;

    $step=$left if $step > $left;

    read  $self->{body},$chunk,$step;
    print {$tmp} $chunk;

    $addr += $step;

  };


  # swap and give
  close $self->{body};
  $self->{body}=$tmp;

  return $self;

};

# ---   *   ---   *   ---
# terminate edit

sub fclose($self) {


  # get filenames
  my $body = $self->ftmp;
  my $dst  = $self->{path} . $self->ext;

  # close tmp files
  close $self->{body};


  # make archive
  open my $fh,'+>',$dst;

  # ^put meta
  my $meta_t=$self->meta_t;

  print {$fh} (pack $meta_t->{packof},

    $self->sig,
    $self->{blk_sz_src},
    $self->{cnt},
    $self->{blkcnt},

    length $self->{head},

  );

  print {$fh} $self->{head};
  close $fh;


  # ^cat em and cleanup
  `cat   $body >> $dst`;
  unlink $body;

  return;

};

# ---   *   ---   *   ---
# look for path in header

sub fetch($self,$path) {


  # file in cache?
  return $self->{cache}->{$path}
  if exists $self->{cache}->{$path};


  # get ctx
  my $limit  = length $self->{head};
  my $head_t = $self->head_t;


  # walk header
  my $addr = 0x00;
  my $out  = undef;

  while($addr < $limit) {


    # read header entry
    my $have=bunpack $head_t,
      \$self->{head},$addr;

    my $elem=$have->{ct}->[0];


    # found requested?
    if($elem->{path} eq $path) {

      $out=$elem;
      $out->{headptr}=$addr;

      last;

    };


    # ^nope, go next
    $addr += (
      $have->{len}
    + length $elem->{path}

    );

  };


  return $out;

};

# ---   *   ---   *   ---
# builds header and zero-pads data

sub pack_elem($self,$pathref,$dataref,$loc) {


  # get ctx
  my $head_t = $self->head_t;
  my $blk_sz = $self->{blk_sz};


  # get required/aligned size
  my $req    = length $$dataref;
  my $ezy    = int_urdiv $req,$blk_sz;

  my $total  = $ezy * $blk_sz;

  # ^zero-pad
  my $diff   = $total-$req;
  $$dataref .= pack "x[$diff]";


  # build header entry
  my $elem=Bpack::layas $head_t,
    $$pathref,$loc,$ezy-1;


  return (\$elem,$total,$ezy);

};

# ---   *   ---   *   ---
# write element at end of table

sub new_elem($self,$pathref,$dataref) {


  # get ctx
  my $head_t=$self->head_t;
  my $blk_sz=$self->{blk_sz};


  # get end of file
  seek $self->{body},0,2;
  my $ptr=tell $self->{body};

  # align and bytepack
  my ($elemref,$total,$ezy)=$self->pack_elem(

    $pathref,
    $dataref,

    int_urdiv $ptr,$blk_sz,

  );

  # ^cat to end of file
  my $have=bpack $head_t,$$elemref;

  $self->{head} .= $have->{ct};
  print {$self->{body}} $$dataref;

  $self->{cnt}++;
  $self->{blkcnt} += $ezy;

  return $total;

};

# ---   *   ---   *   ---
# ^write to specific element

sub update_elem($self,$lkup,$dataref) {


  # get ctx
  my $head_t=$self->head_t;
  my $blk_sz=$self->{blk_sz};


  # get pointers
  my $bodyptr = $lkup->{loc};
  my $headptr = $lkup->{headptr};

  # get old elem size
  my $old_body = ($lkup->{ezy}+1) * $blk_sz;
  my $old_head = (
    $head_t->{sizeof}
  + length $lkup->{path}

  );


  # align and bytepack
  my ($elemref,$new,$ezy)=$self->pack_elem(

    \$lkup->{path},

    $dataref,
    $bodyptr,

  );


  # ^update header entry
  my $have=bpack $head_t,$$elemref;

  substr $self->{head},
    $headptr,
    $old_head,
    $have->{ct};


  # need to move neighbors?
  if($old_body != $new
  && $bodyptr  <  $self->{blkcnt}-1) {

    # separate left and dump new
    my ($dst,$tmp)=
      $self->cut($bodyptr,$old_body);

    print {$self->{body}} $$dataref;

    # ^combine both files and cleanup
    `cat   $tmp >> $dst`;
    unlink $tmp;


    # propagate changes to header
    $self->on_cut($headptr,$old_body,$new);

    $self->{blkcnt} -= int_urdiv $old_body,$blk_sz;
    $self->{blkcnt} += $ezy;


  # ^nope, just write!
  } else {
    seek  $self->{body},($bodyptr) * $blk_sz,0;
    print {$self->{body}} $$dataref;

  };

  return $new;

};

# ---   *   ---   *   ---
# split file at element

sub cut($self,$ptr,$size) {


  # get element position
  my $blk_sz = $self->{blk_sz};
  my $ezy    = int_urdiv $size,$blk_sz;

  # path to [dst => tmp]
  my $body = $self->ftmp;
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
  truncate $self->{body},$ptr * $blk_sz;
  seek     $self->{body},0,2;


  return ($body,$tmp);

};

# ---   *   ---   *   ---
# ^book-keeping

sub on_cut($self,$ptr,$old,$new) {


  # get ctx
  my $limit  = length $self->{head};
  my $blk_sz = $self->{blk_sz};
  my $head_t = $self->head_t;

  # get size change
  my $diff = abs       $new-$old;
     $diff = int_urdiv $diff,$blk_sz;

  $diff = -$diff if $new < $old;


  # walk header from ptr onwards
  my $addr=$ptr;

  while($addr < $limit) {


    # read header entry
    my $have=bunpack $head_t,
      \$self->{head},$addr;

    my $elem=$have->{ct}->[0];


    # ^get size
    my $step=(
      $head_t->{sizeof}
    + length $elem->{path}

    );


    # adjust all entries after first one!
    if($addr > $ptr) {

      $elem->{loc} += $diff;
      $have=bpack $head_t,$elem;

      substr $self->{head},
        $addr,$step,$have->{ct};

    };


    # go next
    $addr += $step;


  };


  return;

};

# ---   *   ---   *   ---
# pack, then update or make new

sub store($self,$path,$type,$data) {


  # pack data and find where to put it ;>
  my $have  = bpack $type,@$data;
  my $lkup  = $self->fetch($path);

  my $total = 0x00;


  # existing path?
  if(! defined $lkup) {
    $total=$self->new_elem(\$path,\$have->{ct});

  } else {
    $total=$self->update_elem($lkup,\$have->{ct});

  };


  return $total;

};

# ---   *   ---   *   ---
# remove element

sub remove($self,$path) {


  # skip if not found
  my $lkup=$self->fetch($path);
  return 0 if ! defined $lkup;


  # get ctx
  my $headptr = $lkup->{headptr};
  my $blk_sz  = $self->{blk_sz};
  my $head_t  = $self->head_t;

  my $head_sz = (
    $head_t->{sizeof}
  + length $lkup->{path}

  );


  # first or middle element?
  if($lkup->{loc} < $self->{blkcnt}-1) {

    # separate left and discard
    my $stop=($lkup->{ezy}+1) * $blk_sz;
    my ($dst,$tmp)=
      $self->cut($lkup->{loc},$stop);

    # ^combine both files and cleanup
    `cat   $tmp >> $dst`;
    unlink $tmp;

    # book-keep
    $self->on_cut($headptr,$stop,0);


  # ^last, truncate only!
  } else {

    truncate $self->{body},
      $lkup->{loc} * $blk_sz;

  };


  # clear header entry
  substr $self->{head},
    $headptr,$head_sz,null;

  $self->{cnt}--;
  $self->{blkcnt} -= $lkup->{ezy}+1;

  return 1;

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

map {
  $daf->store("x$ARG",'word',[(0x24|$ARG) x 9])

} 0..2;

$daf->remove('x1');
$daf->fclose();

# ---   *   ---   *   ---
1; # ret
