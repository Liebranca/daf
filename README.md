# DAF: DARK ARCHIVE FORMAT

A solution for *local* databases, that is, storing __and__ accessing large collections of data on a single machine, without an over-engineered communication layer stuck in the middle: a `daf` instance collects and fetches data, no more and no less.

The archiver works as a kind of virtual file structure, where each entry is accessed through a filepath -- in essence, it maps strings to blocks of data.

`daf` was designed for working with large files, and as such, handles editing without loading the entire archive into memory -- only the file header and table is read, which amounts to around 128KB in a worst-case scenario.

The tradeoff for this reduced memory usage is most operations are I/O bound; whether this makes it less performant in cases where a communication layer is indeed required has not been tested, but is quite likely.


## SETUP

Get [https://github.com/Liebranca/avtomat?tab=readme-ov-file#installation](`avtomat`). Then:

```bash
cd  $ARPATH
git clone https://github.com/Liebranca/daf
cd  daf

./install.pl && ./avto
```

There, you're done.


## USAGE EXAMPLE

```perl

# import
use lib "$ENV{ARPATH}/lib/";
use daf;

# open an archive
my $file=daf->fopen('filename');


# edit element
my $elem =  $file->fetch('path-to/elem');

my $data =  $file->load($elem);
   $data =~ s[\x{00}][$]sxmg;


# ^overwrite and terminate
$file->store($elem,byte=>[$data]);
$file->fclose();

```


## USER METHODS

### daf::new($class,$path,%O)

Make a new archive.

Takes a filepath and a hash holding options `%O`, which recognizes the following arguments:

- `blk_sz` size of each block in the file, expressed as an exponent. The final block size is then equal to `1 << blk_sz+4`.

- `open` 1 if opening an existing file, 0 if making a new one.

The interface method `fnew` makes a new archive, while `fopen` reads an existing one.


### daf::fclose($self)

Saves any edits on an open file, then closes it. This method is not called automatically on destruction.


### daf::fetch($self,$path)

Retrieve the element identified by `$path`, reading only metadata into memory.

`$path` may be a string or string reference.

The returned descriptor can be used by other methods to refer back to this block within the file, wherever a `$path` would be used instead.


### daf::store($self,$path,$type,$data)

Write `$data`, as formatted by `$type`, to the entry identified by `$path`.

Takes a filepath, a typename or type, and an array reference holding the content to pack according to the type's layout.

This method is used both for editing existing elements as well as making new entries.

`$path` may be either a string, string reference, or element descriptor, as returned by `fetch`.


### daf::load($self,$path)

Retrieve the element identified by `$path`, copy it's contents into a string, and return this raw bytearray.

`$path` may be either a string, string reference, or element descriptor, as returned by `fetch`.


### daf::free($self,$path)

Zero-flood the contents of the entry identified by `$path` and mark it as available for reuse.

Any blocks freed by this method that are not reused by a subsequent `store` will be effectively removed from the file during `fclose`.

`$path` may be either a string, string reference, or element descriptor, as returned by `fetch`.


## FILE STRUCTURE

An archive file is divided into table and contents, with a short header storing metadata.

The header has the following attributes:

- Signature: used by other system tools to recognize the file's type.

- Block size: each entry in the content array has a size equal to some multiple of this minimum granularity.
- Element count and block count: used to track how many distinct entries exist in the content array, as well as calculating the total size of the file's body.


The table consists of two arrays:

- The 'fetch mask' holds 64-bit values, used to identify slots in the table as available or in-use.

- The table body itself holds pointers into the file's content, measured in blocks.


Each of these entries in the file's content array, in turn, is broken in two. The first half contains:

- Size of the entry, measured in blocks.

- The path used to access this data.


With size accounting for both, *on top* of the actual contents of the element -- a raw bytearray -- that is stored after the path.

It is worth noting that no other metadata is stored; decoding this raw bytearray is left up to the client.
