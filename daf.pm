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
  use Bpack;

  use Arstd::Path;
  use Arstd::Int;
  use Arstd::IO;
  use Arstd::WLog;
  use Arstd::xd;

  use parent 'St';

# ---   *   ---   *   ---
# info

  our $VERSION = v0.00.5;#a
  our $AUTHOR  = 'IBN-3DILA';

# ---   *   ---   *   ---
# ROM

St::vconst {


  DEFAULT => {
    blk_sz  => 0,

  },


  ext    => '.daf',
  sig    => 0xAFBD,

  tab_t  => sub {

    my $class=$_[0];
    my $struc=struc "$class.tab_t" => q[

      cstr path;

      word loc;
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
      qword break;

    ];

    return $struc;

  },


  freeblk    => "\x{7F}\$S",
  freeblk_re => sub {

    my $class = $_[0];
    my $s     = $class->freeblk;

    return qr{^$s$};

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

    tab    => '',
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


  # read header
  my $head_t = $self->head_t;
  my $head   = undef;

  read $self->{body},
    $head,$head_t->{sizeof};


  # ^unpack and copy to memory
  my $have=bunpack $head_t,\$head;
     $have=$have->{ct}->[0];

  $self->{break}      = $have->{break};
  $self->{cnt}        = $have->{cnt};
  $self->{blkcnt}     = $have->{blkcnt};
  $self->{blk_sz_src} = $have->{blk_sz};

  $self->{blk_sz}     =
    1 << ($have->{blk_sz}+4);


  # read table into memory
  read $self->{body},
    $self->{tab},$self->{break};

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

  # ^put header
  my $head_t=$self->head_t;

  print {$fh} (pack $head_t->{packof},

    $self->sig,
    $self->{blk_sz_src},
    $self->{cnt},
    $self->{blkcnt},

    length $self->{tab},

  );

  print {$fh} $self->{tab};
  close $fh;


  # ^cat em and cleanup
  `cat   $body >> $dst`;
  unlink $body;

  return;

};

# ---   *   ---   *   ---
# look for path in table

sub fetch($self,$path) {


  # file in cache?
  return $self->{cache}->{$path}
  if exists $self->{cache}->{$path};


  # get ctx
  my $limit = length $self->{tab};
  my $tab_t = $self->tab_t;


  # walk table
  my $addr = 0x00;
  my $out  = undef;

  while($addr < $limit) {


    # read table entry
    my $have=bunpack $tab_t,
      \$self->{tab},$addr;

    my $elem=$have->{ct}->[0];


    # found requested?
    if($elem->{path} eq $path) {

      $out=$elem;
      $out->{tabptr}=$addr;

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
# align and zero-pad input data

sub pack_data($self,$type,$data) {


  # get ctx
  my $blk_sz = $self->{blk_sz};


  # layas struc
  my $have    = bpack $type,@$data;
  my $dataref = \$have->{ct};

  # get required/aligned size
  my $req    = length $$dataref;
  my $ezy    = int_urdiv $req,$blk_sz;

  my $total  = $ezy * $blk_sz;

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
# write element at end of table

sub new_elem($self,$pathref,$data) {


  # get ctx
  my $tab_t  = $self->tab_t;
  my $blk_sz = $self->{blk_sz};


  # get end of file
  seek $self->{body},0,2;
  my $ptr=tell $self->{body};

  # align and bytepack
  my $elem=Bpack::layas(

    $self->tab_t,
    $$pathref,

    int_urdiv($ptr,$blk_sz),
    $data->{ezy}-1

  );

  # ^cat to end of file
  my $have=bpack $tab_t,$elem;

  $self->{tab} .= $have->{ct};
  print {$self->{body}} ${$data->{bytes}};

  $self->{cnt}++;
  $self->{blkcnt} += $data->{ezy};

  return;

};

# ---   *   ---   *   ---
# ^write to specific element

sub update_elem($self,$lkup,$data) {


  # get ctx
  my $tab_t  = $self->tab_t;
  my $blk_sz = $self->{blk_sz};


  # get pointers
  my $bodyptr = $lkup->{loc};
  my $tabptr  = $lkup->{tabptr};

  # get old elem size
  my $old_body = ($lkup->{ezy}+1) * $blk_sz;
  my $old_tab  = (
    $tab_t->{sizeof}
  + length $lkup->{path}

  );


  # align and bytepack
  my $elem=Bpack::layas(

    $self->tab_t,

    $lkup->{path},

    $bodyptr,
    $data->{ezy}-1

  );


  # ^update table entry
  my $have=bpack $tab_t,$elem;

  substr $self->{tab},
    $tabptr,
    $old_tab,
    $have->{ct};


  # need to move neighbors?
  if($old_body != $data->{total}
  && $bodyptr  <  $self->{blkcnt}-1) {

    # separate left and dump new
    my ($dst,$tmp)=
      $self->cut($bodyptr,$old_body);

    print {$self->{body}} ${$data->{bytes}};

    # ^combine both files and cleanup
    `cat   $tmp >> $dst`;
    unlink $tmp;


    # propagate changes to table
    $self->on_cut(
      $tabptr,
      $old_body,
      $data->{total}

    );

    $self->{blkcnt} -= int_urdiv $old_body,$blk_sz;
    $self->{blkcnt} += $data->{ezy};


  # ^nope, just write!
  } else {
    seek  $self->{body},($bodyptr) * $blk_sz,0;
    print {$self->{body}} ${$data->{bytes}};

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
  my $limit  = length $self->{tab};
  my $blk_sz = $self->{blk_sz};
  my $tab_t  = $self->tab_t;

  # get size change
  my $diff = abs       $new-$old;
     $diff = int_urdiv $diff,$blk_sz;

  $diff = -$diff if $new < $old;


  # walk table from ptr onwards
  my $addr=$ptr;

  while($addr < $limit) {


    # read table entry
    my $have=bunpack $tab_t,
      \$self->{tab},$addr;

    my $elem=$have->{ct}->[0];


    # ^get size
    my $step=(
      $tab_t->{sizeof}
    + length $elem->{path}

    );


    # adjust all entries after first one!
    if($addr > $ptr) {

      $elem->{loc} += $diff;
      $have=bpack $tab_t,$elem;

      substr $self->{tab},
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
  my $have = $self->pack_data($type,$data);
  my $lkup = $self->alloc($path,$have->{ezy}-1);


  # existing path?
  if(! defined $lkup) {
    $self->new_elem(\$path,$have);

  } else {
    $self->update_elem($lkup,$have);

  };


  return $have->{total};

};

# ---   *   ---   *   ---
# remove element

sub remove($self,$path) {


  # skip if not found
  my $lkup=$self->fetch($path);
  return 0 if ! defined $lkup;


  # get ctx
  my $tabptr = $lkup->{tabptr};
  my $blk_sz = $self->{blk_sz};
  my $tab_t  = $self->tab_t;

  my $tab_sz = (
    $tab_t->{sizeof}
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
    $self->on_cut($tabptr,$stop,0);


  # ^last, truncate only!
  } else {

    truncate $self->{body},
      $lkup->{loc} * $blk_sz;

  };


  # clear table entry
  substr $self->{tab},
    $tabptr,$tab_sz,null;

  $self->{cnt}--;
  $self->{blkcnt} -= $lkup->{ezy}+1;

  return 1;

};

# ---   *   ---   *   ---
# mark entry as avail

sub free($self,$path) {


  # skip if not found
  my $lkup=(! is_hashref $path)
    ? $self->fetch($path)
    : $path
    ;

  return 0 if ! defined $lkup;


  # get ctx
  my $tabptr = $lkup->{tabptr};
  my $blk_sz = $self->{blk_sz};
  my $tab_t  = $self->tab_t;


  # we identify free entries by placing
  # a special value in the path ;>
  $lkup->{path}=$self->freeblk;

  my $tab_sz = (
    $tab_t->{sizeof}
  + length $lkup->{path}

  );

  # ^write back to table
  my $have=bpack $tab_t,$lkup;
     $have=$have->{ct};

  substr $self->{tab},
    $lkup->{tabptr},
    $tab_sz,
    $have;


  # zero-flood content
  #
  # this is not strictly necessary,
  # but it'll likely make the file
  # compress better
  my $ezy=($lkup->{ezy}+1) * $blk_sz;

  seek  $self->{body},$lkup->{loc} * $blk_sz,0;
  print {$self->{body}} pack "x[$ezy]";


  return 1;

};

# ---   *   ---   *   ---
# find block matching path and size
#
# if none found, look for
# a free block matching size

sub alloc($self,$path,$ezy) {


  # get ctx
  my $limit   = length $self->{tab};
  my $tab_t   = $self->tab_t;
  my $freeblk = $self->freeblk;


  # walk table
  my $addr  = 0x00;

  my $req   = undef;
  my $avail = undef;
  my $out   = undef;


  while($addr < $limit) {


    # read table entry
    my $have=bunpack $tab_t,
      \$self->{tab},$addr;

    my $elem=$have->{ct}->[0];


    # found requested?
    if($elem->{path} eq $path) {

      $req=$elem;
      $req->{tabptr}=$addr;

      # stop if size matches ;>
      $out=$req if $elem->{ezy} eq $ezy;


    # ^found free block matching size?
    } elsif(
       $elem->{path} eq $freeblk
    && $elem->{ezy}  eq $ezy

    ) {

      $avail=$elem;
      $avail->{tabptr} = $addr;
      $avail->{path}   = $path;


      # backup to this block if
      # requested doesn't fit!
      $out=$avail if defined $req;

    };

    last if defined $out;


    # ^nope, go next
    $addr += (
      $have->{len}
    + length $elem->{path}

    );

  };


  $out //= $avail;
  return $out;

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

$daf->free('x1');
$daf->store('x1','word',[(0x2424) x 9]);
$daf->fclose();

# ---   *   ---   *   ---
1; # ret
