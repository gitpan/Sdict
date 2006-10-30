# $RCSfile: Sdict.pm,v $
# $Author: swaj $
# $Revision: 1.35 $
#
# Copyright (c) Alexey Semenoff 2001-2006. All rights reserved.
# Distributed under GNU Public License.
#


use 5.008;
use strict;
use warnings;

package Sdict;

use Encode qw / encode decode from_to /;
use IO::File;
use Getopt::Long;
use Data::Dumper;

require Exporter;

use vars qw(
	    @ISA
	    @EXPORT
	    @EXPORT_OK
	    %EXPORT_TAGS
	    $VERSION
	    $PACKAGE
	    $debug
	    $errstr
	    %COMPRESSION

	    $W_LANG_POS
	    $A_LANG_POS
	    $WORDS_TOT_PTR_POS
	    $SINDEX_TOT_PTR_POS
	    $SINDEX_PTR_POS
	    $FINDEX_PTR_POS
	    $ARTICLES_PTR_POS
	    $COMPRESSOR_POS
	    $TITLE_PTR_POS
	    $COPYRIGHT_PTR_POS
	    $VERSION_PTR_POS
	    $sort_table
	    $sort_table_pl
	    );

$VERSION = '2.8';

@ISA = qw(Exporter);

@EXPORT = qw(
	     &prinfo
	     &prerror
	     );

use constant {

    COMPRESSOR_NONE          => 'none'          ,
    COMPRESSOR_GZIP          => 'gzip'          ,
    COMPRESSOR_BZIP2         => 'bzip2'         ,
    GZIP_COMPRESSION_LEVEL   => 9               ,
    BZIP2_COMPRESSION_LEVEL  => 9               ,

    SDICT_SIG                => 'sdct'          ,
    SDICT_HEADER_SIZE        => 43              ,
    SDICT_SOURCE_FILE_SEP    => '___'           ,
    SDICT_SOURCE_FILE_SEP_O  => '___'           ,
    SDICT_WORD_MAX_SIZE      => 65535 - 8       ,
    SDICT_ART_MAX_SIZE       => 4294967295 - 4  ,

    SDICT_SHORT_NDX_LEN      => 3               ,
    SDICT_SHORT_NDX_LEN_MAX  => 15              ,
    SINDEX_ITEM_LEN          => 3 * 4 + 4       , # SDICT_SHORT_NDX_LEN * 4 + 4,

    SDICT_FILE_EXT           => '.dct'          ,
    SDICT_SEARCH_FORWARD     => 15000           ,
    SDICT_SINDEX_WARN        => 1940000         ,
};

sub prerror (@);
sub prinfo (@);
sub help ($);
sub help_and_quit ($);
sub prline (@);
sub init ($%);
sub parse_args($);
sub convert($);
sub print_dct_info ($);


BEGIN {
      $_=$0;
      s|^(.+)/.*|$1|;
      push @INC, (
		  $_,
		  "$_/lib",
		  "$_/../lib",
		  "$_/.."
		  ) ;

      %COMPRESSION = qw / none 0 gzip 1 bzip2 2 /;

      $W_LANG_POS = 4;
      $A_LANG_POS = 7;
      $COMPRESSOR_POS     = hex ( "0xa"  );
      $WORDS_TOT_PTR_POS  = hex ( "0xb"  );
      $SINDEX_TOT_PTR_POS = hex ( "0xf"  );
      $TITLE_PTR_POS      = hex ( "0x13" );
      $COPYRIGHT_PTR_POS  = hex ( "0x17" );
      $VERSION_PTR_POS    = hex ( "0x1b" );
      $SINDEX_PTR_POS     = hex ( "0x1f" );
      $FINDEX_PTR_POS     = hex ( "0x23" );
      $ARTICLES_PTR_POS   = hex ( "0x27" );

      $debug = 0;
      $PACKAGE = __PACKAGE__;
};


sub new () {
    my $class = shift;
    my $self  = {};
    $self->{ init } = 0;

    my $cpu = q{};
    $self->{ big_endian } = 0;

    eval { use Config; $cpu = $Config{byteorder};  };

    if ($@ || !$cpu) {
	warn "unable to get CPU type";
    }

    $self->{ big_endian } = 1 if ($cpu eq '4321' || $cpu eq '87654321');

    # TODO: add support for big-endian
    die "\nERROR: Big-endian systems are not yet supported!\n" if ($self->{ big_endian });

    return bless $self, $class;
}


sub help ($) {

    print <<EOS;
------------------------------------------------------------------------------
Usage: $0
   --compile                 |   The main action which 
   --decompile               |   should be one of these
   --analyze[=max]           |   commands
   --printinfo

   --input-file=filename         Input filename
   [ --output-file=filename  ]   Output filename

   [ --sindex-levels=3-15    ]   Number of short index levels, default is 3

                                 Sort words before packing:
   [ --sort=sort_table[.pl]  ]   - table sorting
   [ --sort=Unicode::Collate ]   - use Unicode::Collate for sorting
   [ --sort=numeric          ]   - numeric sorting

   [ --compression=none|gzip ]   Use compression; default is none,
                                 gzip is better choice 
   [ --lowercase-alias       ]   Duplicate word list with lowercase
                                 aliases (useful for PDA)
   [ --force-to-lowercase    ]   Force all words to lowercase first
   [ --disable-duplicates    ]   Stop with an error if duplicate words found
   [ --fool-terminal         ]   Force to use non-Unicode terminal output
------------------------------------------------------------------------------
EOS
}


sub help_and_quit ($) {
    help ( shift );
    exit 1;
}


sub prerror (@) {
    print STDERR "\nERROR ($PACKAGE)! @_\n\n";
}


sub prinfo (@) {
    $debug && print "INFO ($PACKAGE): @_\n";
}


sub prline (@) {
    print ">>> @_\n";
}


sub debug_on {
    $debug = 1;
}


sub debug_off {
    $debug = 0;
}


sub parse_args ($) {
    my $class = shift;

    my (
	$compile,
	$decompile,
	$infile,
	$outfile,
	$compressor,
	$sort,
	$slevels,
	$analyze,
	$lowercasealias,
	$forcetolowercase,
	$disableduplicates,
	$printinfo,
	$convertcharset,
	);

    GetOptions(

	       "compile"            => \$compile,
	       "decompile"          => \$decompile,
	       "analyze=s"          => \$analyze,
	       "input-file=s"       => \$infile,
	       "output-file=s"      => \$outfile,
	       "sort=s"             => \$sort,
	       "compression=s"      => \$compressor,
	       "sindex-levels=s"    => \$slevels,
	       "lowercase-alias"    => \$lowercasealias,
	       "force-to-lowercase" => \$forcetolowercase,
	       "disable-duplicates" => \$disableduplicates,
	       "printinfo"	    => \$printinfo,
	       "fool-terminal"      => \$convertcharset, 
	       );

    prinfo "Started, module version $VERSION";

    $class->help_and_quit if ( $compile && $decompile );
    $class->help_and_quit unless ( $compile || $decompile || $analyze || $printinfo );
    $class->help_and_quit if ( $infile eq q{} );

    $outfile = q{} unless defined ($outfile);

    if ( $outfile eq q{} ) { 
	$class->help_and_quit if ( !defined ($analyze) && !defined ($printinfo) ); 
    }

    $class->{ infile  } = $infile;
    $class->{ outfile } = $outfile;

    $class->{ action      } = 'compile'   if ( $compile   );
    $class->{ action      } = 'decompile' if ( $decompile );
    $class->{ action      } = 'analyze'   if ( $analyze   );
    $class->{ action      } = 'printinfo' if ( $printinfo );
    $class->{ analyze_max } = $analyze;

    $class->help_and_quit unless ( $class->{ action } );

    $class->{ sort           } = $sort           || 0;
    $class->{ convertcharset } = $convertcharset || 0;

    unless ($compressor) {
	$class->{ compressor } = COMPRESSOR_NONE;
    }
    elsif ( $compressor eq COMPRESSOR_NONE ) {
 	$class->{ compressor } = COMPRESSOR_NONE;
    }
    elsif ( $compressor eq COMPRESSOR_GZIP ) {
	$class->{ compressor } = COMPRESSOR_GZIP;

	eval 'use Compress::Zlib';
	if ( $@ ) {
	    prerror "Unable to load compression module 'Compress::Zlib' $@";
	    exit 1;
	}

    }
    elsif ( $compressor eq COMPRESSOR_BZIP2 ) {
	$class->{ compressor } = COMPRESSOR_BZIP2;
	eval 'use Compress::Bzip2';
	if ( $@ ) {
	    prerror "Unable to load compression module 'Compress::Bzip2' $@";
	    exit 1;
	}
	prerror 'This compression method is not tested!';
	exit 1;

    }
    else {
	prerror 'Wrong compression or short index levels value';
	$class->help_and_quit;
    }


    unless ( $slevels ) {
	$class->{ slevels } = SDICT_SHORT_NDX_LEN;
    }
    else {
	$class->{ slevels } = $slevels;
    }

    if ( ( $class->{ slevels } < SDICT_SHORT_NDX_LEN ) || 
	 ( $class->{ slevels } > SDICT_SHORT_NDX_LEN_MAX ) ) {
	prerror "Invalid 'sindex-levels' value, must be between 3 and 15";
	$class->help_and_quit;
    }

    if ( $forcetolowercase && $lowercasealias ) {
	prerror "Both '--force-to-lowercase' and '--lowercasealias' can't be specified in the same time";
	$class->help_and_quit;
    }

    unless ( $lowercasealias ) {
	$class->{ lowercasealias } = 0;
    }
    else {
	$class->{ lowercasealias } = $lowercasealias;
    }

    unless ( $forcetolowercase ) {
	$class->{ forcetolowercase } = 0;
    }
    else {
	$class->{ forcetolowercase } = $forcetolowercase;
    }

    unless ( $disableduplicates ) {
	$class->{ disableduplicates } = 0;
    }
    else {
	$class->{ disableduplicates } = $disableduplicates;
    }


    $class->{ init } = 1;
    prinfo 'Initialization OK!';
    return 1;
}


sub convert ($) {
    my $class = shift;

    if ( $class->{ action } eq 'compile' ) {
	return $class->compile;
    }
    elsif ( $class->{ action } eq 'decompile' ) {
	return $class->decompile;
    }
    elsif ( $class->{ action } eq 'analyze' ) {
	return $class->analyze;
    }
}


sub init ($%) {
    my ( $class, $params ) = @_[ 0, 1 ]; 
    $class->{ infile } = $params->{ file };
    $class->{ init } = 1;
    return 1;
}


sub convert_charset_ai {
    my ($class, $string) = @_; 

    return unless ( $class->{ convertcharset } );

    my $charset_to = ( $class->{ header }->{ w_lang } eq 'ru' ) ? 'koi8-r' : 'iso-8859-1' ;
    from_to ( $class->{ header }->{ title     }, "utf8", $charset_to ); 
    from_to ( $class->{ header }->{ copyright }, "utf8", $charset_to ); 
}


sub print_dct_info ($) {
    my $class = $_[0]; 

    die "Unable load dictionary, file '$class->{ infile }'\n" unless $class->load_dictionary_fast;

#    print Dumper $class;

    $class->convert_charset_ai;

    my $size = (stat ($class->{ infile }))[7];

    print <<EOS;
+------------------------------------------------------------------------------
| Dictionary information ($class->{ infile }, $size bytes):
|
| Title        $class->{ header }->{ title }
| Copyright    $class->{ header }->{ copyright }
| Languages    $class->{ header }->{ w_lang }/$class->{ header }->{ a_lang }
| Version      $class->{ header }->{ version }
| Word(s)      $class->{ header }->{ words_total }
| Indices      $class->{ slevels }+1
| Compression  $class->{ compressor }
+------------------------------------------------------------------------------
EOS


    $class->unload_dictionary;
    return 1;
}


sub search_word ($$) {
    my ( $class, $word ) = @_;

    if ( $word  eq q{} ) {
	prerror 'Wrong arguments';
	return q{};
    }

    unless ( defined ( $class->{ header } ) ) {
	prerror 'Class is not initialized';
	return q{};
    }

    prinfo "Searching for '$word'";

    my $word_u = decode ( "utf8", $word );
    my $ref;
    my $search_pos = -1;

    my $len = length ( $word_u );
    my $subw = substr ( $word_u, 0, 3 );

    return q{} unless $len;
    
    for ( my $i=1; $i<4; $i++ ) {

	if ( $i == 1 ) {
	    $ref = $class->{ sindex_1 };
	}
	elsif ( $i == 2 ) {
	    $ref = $class->{ sindex_2 };
	}
	else  {
	    $ref = $class->{ sindex_3 };
	}
	
	for my $j ( @$ref ) {
	    my ( $wo, $ndx ) = @$j;
	    if ( substr( $wo, 0, $i ) eq substr( $subw, 0, $i ) ) {
		# prinfo "Found in '$i', wo: '$wo', ndx: '$ndx'";
		$search_pos = $ndx;
		next;
	    }
	}
    }

    if ( $search_pos < 0 ) {
	prinfo 'Not found';
	return q{};
    }

    # prinfo "Scanning from pos '$search_pos'";

    my $findes_saved = $class->{ f_index_pos_cur };

    $class->{ f_index_pos_cur } = $search_pos + $class->{ f_index_pos };

    for ( my $ii=0; $ii < SDICT_SEARCH_FORWARD; $ii++ ) {
	my $prev_pos = $class->{f_index_pos_cur};
	my $nw = $class->get_next_word;

	if ( $nw eq q{} ) {
	    $class->{ f_index_pos_cur } = $findes_saved;   
	    prinfo 'Not found';
	    return q{};
	}

	$nw = decode ( "utf8", $nw );

	if ( substr ( $word_u, 0, 3 ) ne substr( $nw, 0, 3 ) ) {
	    prinfo 'Not found';
	    return q{};
	}

	if ( $word_u eq $nw ) {

	    my $art = $class->read_unit (
					 $class->{ cur_word_pos } +
					 $class->{ articles_pos }
					 );

	    return q{} if ( $art eq q{} );
	    return $art;
	}
    }
    prinfo 'Not found';
    return q{};
}


sub load_dictionary ($) {
    my $class = shift;
 
    prinfo 'Reading header';
    return 0 unless $class->read_header;

    prinfo 'Reading full index';    
    return 0 unless $class->read_full_index;

    prinfo 'Reading short index';
    return 0 unless $class->read_short_index;

    return 1;
}


sub load_dictionary_fast ($) {
    my $class = shift;
 
    prinfo 'Reading header';
    return 0 unless $class->read_header;

    # print Dumper $class; die;

    prinfo 'Reading short index fast';
    return 0 unless $class->read_short_index_fast;

    $class->{ f_index_pos_cur } = $class->{ f_index_pos };
  
    return 1;
}


sub get_next_word ($) {
    my $class = shift;
    my $file = $class->{ infile_handler };
    my $fpos = $class->{ f_index_pos_cur };
    my $hdr = q{};

    my (
	$next,
	$aptr,
	$wlen,
	$word
	);

    unless ( sysseek ( $file, $fpos, 0 ) ) {
	prerror "Seek error: $!";
	exit 1;
    }

    unless (sysread ($file, $hdr, 8, 0)) {
	prerror "Sysread error: $!";
	exit 1;
    }

	$next = unpack ( "S", substr ( $hdr, 0, 2 ) );

    unless ( $next ) {
	prinfo 'Last word reached';
	return q{};
    }

    $aptr = unpack ( "L", substr ( $hdr, 4, 4 ) );

    $wlen = $next - 4 - 2 - 2;

    if ( $wlen < 0 ) {
	prerror 'File format error';
	exit 1;
    }

    unless ( sysread ( $file, $word, $wlen, 0 ) ) {
	prerror "Sysread error: $!";
	exit 1;
    }

    $class->{ cur_word        } =  $word;
    $class->{ cur_word_pos    } =  $aptr;
    $class->{ f_index_pos_cur } += $wlen + 8;

    return $word;
}


sub get_prev_word ($) {
    my $class = shift;
    my $file = $class->{ infile_handler };
    my $fpos = $class->{ f_index_pos_cur };
    my $hdr = q{};
    my ( $next, $prev, $aptr, $wlen, $word );


    unless ( sysseek( $file, $fpos, 0 ) ) {
	prerror "Seek error: $!";
	exit 1;
    }

    unless ( sysread ( $file, $hdr, 8, 0 ) ) {
	prerror "Sysread error: $!";
	exit 1;
    }

    $prev = unpack ( "S", substr ( $hdr, 2, 2 ) );

    unless ( $prev ) {
	prinfo 'First word reached';
	return q{};
    }

    unless ( sysseek ( $file, $fpos - $prev, 0 ) ) {
	prerror "Seek error: $!";
	exit 1;
    }

    unless ( sysread ( $file, $hdr, 8, 0 ) ) {
	prerror "Sysread error: $!";
	exit 1;
    }

    $next = unpack ( "S", substr ( $hdr, 0, 2 ) );
    
    $aptr = unpack ( "L", substr ( $hdr, 4, 4 ) );

    $wlen = $next - 4 - 2 - 2;

    if ( $wlen < 0 ) {
	prerror 'File format error';
	exit 1;
    }

    unless ( sysread ( $file, $word, $wlen, 0 ) ) {
	prerror "Sysread error: $!";
	exit 1;
    }

    $class->{ cur_word        } = $word;
    $class->{ cur_word_pos    } = $aptr;
    $class->{ f_index_pos_cur } = $fpos - $prev;

    return $word;
}


sub read_short_index_fast ($) {
    my $class = shift;
    my $file = $class->{ infile_handler };

    # my $sindex_len =  $class->{ header }->{ sindex_total } * SINDEX_ITEM_LEN;
    # SINDEX_ITEM_LEN          => 3 * 4 + 4       , # SDICT_SHORT_NDX_LEN * 4 + 4,

    my $sindex_len =  $class->{ header }->{ sindex_total } *
	( $class->{ slevels } * 4 + 4 );


    my $sindex   = q{};
    my $sindex_d = q{};
    my (
	$sword_u,
	$word_ptr,
	$fiunit,
	$word,
	$i
	);


    my %sindex_words = ();
    my %temp_index = ();

    unless ( sysseek ( $file, $class->{ header }->{ sindex_ptr }, 0 ) ) {
	prerror "Seek error: $!";
	exit 1;
    }

    unless ( sysread ( $file, $sindex, $sindex_len, 0 ) ) {
	prerror "Sysread error: $!";
	return q{};
    }

    # my $co = unpack ( "C",  $class->{ compressor } );
    # warn  ">$co< \n";
    # exit ;

    if ( $class->{ compressor } eq COMPRESSOR_NONE ) {
	prinfo 'No decompression needed';
	$sindex_d = $sindex;

    }
    elsif ($class->{ compressor } eq COMPRESSOR_GZIP ) {
	prinfo 'Decompressing short index using gzip';
	$sindex_d = uncompress ( $sindex, GZIP_COMPRESSION_LEVEL );

	unless ( $sindex_d ) {
	    prerror ("Decompression failed");
	    exit 1;
	}

    }
    elsif ( $class->{ compressor } eq COMPRESSOR_BZIP2 ) {
	prinfo 'Decompressing short index using bgzip2';
	$sindex_d = Compress::Bzip2::uncompress ( $sindex, GZIP_COMPRESSION_LEVEL );

	unless ( $sindex_d ) {
	    prerror ("Decompression failed");
	    exit 1;
	}
    }
    else {
	prerror 'Wrong compression';
	exit 1;
    }

    $i = 0;

    my @sindex_1 = ();
    my @sindex_2 = ();
    my @sindex_3 = ();

    my $sindex_skipped = 0;

    for ( $i=0; $i < $class->{ header }->{ sindex_total }; $i++ ) { 
	my $sword = substr (
			    $sindex_d,
			    # $i * SINDEX_ITEM_LEN,
			    $i * ( $class->{ slevels } * 4 + 4 ),
			    # SDICT_SHORT_NDX_LEN * 4
			    ( $class->{ slevels } * 4 )
			    );

	from_to ( $sword, "UTF-32LE", "utf8" );
	$sword_u = $sword;
	$sword_u =~ s|\x0||g;
	$sword_u = decode ( "utf8", $sword_u );

	$word_ptr = unpack (
			    "L",
			    substr (
				    $sindex_d,
				    # $i * SINDEX_ITEM_LEN + SDICT_SHORT_NDX_LEN * 4,
				    $i * ( $class->{ slevels } * 4 + 4 ) + ( $class->{ slevels } * 4 ), 
				    4
				    )
			    );

	if ( length ( $sword_u ) == 1 ) {
	    push @sindex_1, [ $sword_u, $word_ptr ];
	}
	elsif ( length ( $sword_u ) == 2 ) {
	    push @sindex_2, [ $sword_u, $word_ptr ];
	}
	elsif ( length ( $sword_u ) == 3 ) {
	    push @sindex_3, [ $sword_u, $word_ptr ];
	}
	else {
	    if ( $class->{ slevels } > 3 ) {
		$sindex_skipped++;
		# ok!
	    }
	    else {
		die "Sindex too big for '$sword_u'";
	    }
	}
    }

    $class->{ header }->{ sindex_total } -= $sindex_skipped ;

    $class->{ sindex_1 } = \@sindex_1;
    $class->{ sindex_2 } = \@sindex_2;
    $class->{ sindex_3 } = \@sindex_3;

    # print Dumper $class;
    return 1;
}


sub unload_dictionary ($) {
    my $class = shift;

    prinfo 'Unloading dictionary';
    $class->{ words_list  } = undef;
    $class->{ words_hash  } = undef;
    $class->{ sindex_hash } = undef;
    $class->{ header      } = undef;

    $class->{ sindex_1    } = undef;
    $class->{ sindex_2    } = undef;
    $class->{ sindex_3    } = undef;

    $class->{ infile      } = q{};
    $class->{ init        } = 0;

    return 1;
}


sub decompile ($) {
    my $class = shift;

    my (
	$w_lang,
	$a_lang,
	$title,
	$copyright,
	$version
	);

    my $infile  = $class->{ infile  };
    my $outfile = $class->{ outfile };

    unless ( open ( OF, "> $outfile" ) ) {
	prerror "Unable create file '$outfile': $!";
	exit 1;
    }

    print OF "#\n# Converted from $infile by $0\n#\n";

    $class->{ outfile_handler } = *OF;

    prinfo 'Reading header';
    $class->read_header;

    $title     = $class->{ header }->{ title     };
    $copyright = $class->{ header }->{ copyright };
    $version   = $class->{ header }->{ version   };
    $w_lang    = $class->{ header }->{ w_lang    };
    $a_lang    = $class->{ header }->{ a_lang    };

    print OF <<EOS;
<header>
title = $title
copyright = $copyright
version = $version
w_lang = $w_lang
a_lang = $a_lang
</header>
#
# Begin of articles
#
EOS

    prinfo 'Reading full index';
    $class->read_full_index;

    prinfo 'Dumping words';
    $class->dump_all_words;

    close ( IF );
    close ( OF );

    prinfo 'Done';
    return 1;
}


sub read_header ($) {
    my $class = shift;
    my $hdr;

    my (
	$w_lang,
	$a_lang,
	$compr,
	$compr_method,
	$tot_words,
	$title_ptr,
	$copyr_ptr,
	$version_ptr,
	$f_index_ptr,
	$articles_ptr,
	$unit,
	$title,
	$copyright,
	$sindex_total,
	$sindex_pos,
	$version
	);

    my $infile = $class->{ infile };
    
    unless ( sysopen ( IF, $infile, O_RDONLY ) ) {
	prerror "Unable to open file '$infile':$!";
	return 0;
    }

    unless ( sysread ( IF, $hdr, SDICT_HEADER_SIZE, 0 ) ) {
	prerror "Unable to sysread from file '$infile':$!";
	return 0;
    }

    $class->{ infile_handler } = *IF;

    if ( substr ( $hdr, 0, 4 ) ne SDICT_SIG ) {
	prerror "Wrong signature file '$infile':$!";
	return 0;
    }

    $w_lang = substr ( $hdr, $W_LANG_POS, 3 );
    $a_lang = substr ( $hdr, $A_LANG_POS, 3 );

    $w_lang =~ s|\x0||g;
    $a_lang =~ s|\x0||g;

    $compr =  substr ( $hdr, $COMPRESSOR_POS, 1 );


    my $co = unpack ( "C",  $compr );
    my $cot = $co;
    $cot &= hex ( "xf0" );
    $cot >>= 4;

    $class->{ slevels } = $cot ;

    $cot = $co;
    $cot &= hex ( "x0f" );
    $cot |= hex ( "x30" );

    $compr = pack ( "C" , $cot );

    if ( $compr eq '0' ) {
	$compr_method = COMPRESSOR_NONE;
    }
    elsif ( $compr eq '1' ) {
	$compr_method = COMPRESSOR_GZIP;
    }
    elsif ( $compr eq '2' ) {
	$compr_method = COMPRESSOR_BZIP2;
    }
    else {
	prerror "Wrong compression type '$compr'";
	return 0;
    }

    $class->{ compressor } = $compr_method;

    if ( $compr_method eq COMPRESSOR_GZIP ) {
	eval 'use Compress::Zlib';
	if ( $@ ) {
	    prerror "Unable to load compression module 'Compress::Zlib' $@";
	    return 0;
	}
    }
    elsif ( $compr_method eq COMPRESSOR_BZIP2 ) {
	eval 'use Compress::Bzip2';
	if ( $@ ) {
	    prerror "Unable to load compression module 'Compress::Bzip2' $@";
	    return 0;
	}
    }

    $tot_words    = unpack ( "L", substr ( $hdr, $WORDS_TOT_PTR_POS,  4 ) );
    $title_ptr    = unpack ( "L", substr ( $hdr, $TITLE_PTR_POS,      4 ) );
    $copyr_ptr    = unpack ( "L", substr ( $hdr, $COPYRIGHT_PTR_POS,  4 ) );
    $f_index_ptr  = unpack ( "L", substr ( $hdr, $FINDEX_PTR_POS,     4 ) );
    $articles_ptr = unpack ( "L", substr ( $hdr, $ARTICLES_PTR_POS,   4 ) );
    $sindex_total = unpack ( "L", substr ( $hdr, $SINDEX_TOT_PTR_POS, 4 ) );
    $sindex_pos   = unpack ( "L", substr ( $hdr, $SINDEX_PTR_POS,     4 ) );
    $version_ptr  = unpack ( "L", substr ( $hdr, $VERSION_PTR_POS,    4 ) );

    $title = read_unit ( $class, $title_ptr );
    unless ( $title ) {
	prerror 'Unable to read title';
	return 0;
    }

    $copyright = read_unit ( $class, $copyr_ptr );
    unless ( $copyright ) {
	prerror 'Unable to read copyright';
	return 0;
    }

    $version = read_unit ( $class, $version_ptr ); 
    if ( $version eq q{} ) {
	prerror 'Unable to read version';
	return 0;
    }

    $class->{ f_index_pos  } = $f_index_ptr;
    $class->{ articles_pos } = $articles_ptr;

    prinfo 'Dictionary information:';
    prinfo "   Title: '$title'";
    prinfo "   Copyright: '$copyright'";
    prinfo "   Version: '$version'";
    prinfo "   Langs: $w_lang/$a_lang";
    prinfo "   Words: $tot_words";
    prinfo "   Short index: $sindex_total";
    prinfo "   Compression: $compr_method";
    prinfo ' ';
    prinfo "   Short index offset: ", sprintf ( "0x%x", $sindex_pos   );
    prinfo "   Full index offset : ", sprintf ( "0x%x", $f_index_ptr  );
    prinfo "   Articles offset   : ", sprintf ( "0x%x", $articles_ptr );
    prinfo ' ';

    $class->{ header }->{ title        } = $title;
    $class->{ header }->{ copyright    } = $copyright;
    $class->{ header }->{ version      } = $version;
    $class->{ header }->{ w_lang       } = $w_lang;
    $class->{ header }->{ a_lang       } = $a_lang;

    $class->{ header }->{ words_total  } = $tot_words;
    $class->{ header }->{ sindex_total } = $sindex_total;
    $class->{ header }->{ sindex_ptr   } = $sindex_pos;

    $class->{ header }->{ f_index_pos  } = $f_index_ptr;
    $class->{ header }->{ articles_pos } = $articles_ptr;

    return 1;
}


sub read_full_index ($) {
    my $class = shift;
    my %words_hash = ();
    my @words_list = ();
    my $file = $class->{ infile_handler };
    my $fpos = $class->{ f_index_pos };
    my $hdr = q{};
    my (
	$next,
	$aptr,
	$wlen,
	$word
	);

    unless ( sysseek ( $file, $fpos, 0 ) ) {
	prerror "Seek error: $!";
	exit 1;
    }

    #for( my $i=0; $i < $class->{ header }->{ words_total }    ; $i++) {
    for ( my $i=0; $i < $class->{ header }->{ words_total } * 2; $i++) {

	unless (sysread ($file, $hdr, 8, 0)) {
	    prerror "Sysread error: $!";
	    exit 1;
	}

        $next = unpack ( "S", substr ( $hdr, 0, 2 ) );
        $aptr = unpack ( "L", substr ( $hdr, 4, 4 ) );

	$wlen = $next - 4 - 2 - 2;

	if ( $next == 0 ) {
	    prinfo 'Last word found';
	    last;
	}

	if ( $wlen < 0 ) {
	    prerror 'File format error';
	    exit 1;
	}

	unless ( sysread ( $file, $word, $wlen, 0 ) ) {
	    prerror "Sysread error: $!";
	    exit 1;
	}

	push @words_list, $word;
	$words_hash{ $word } = $aptr;
    }

    $class->{ words_list } = \@words_list;
    $class->{ words_hash } = \%words_hash;
}


sub read_short_index ($) {
    my $class = shift;
    my $file = $class->{ infile_handler };
    my $sindex_len = $class->{ header }->{ sindex_total } * SINDEX_ITEM_LEN;
    my $sindex = q{};
    my $sindex_d = q{};
    my (
	$sword_u,
	$word_ptr,
	$fiunit,
	$word,
	$i
	);
    my %sindex_words = ();
    my %temp_index = ();

    unless ( sysseek ( $file, $class->{ header }->{ sindex_ptr }, 0 ) ) {
	prerror "Seek error: $!";
	exit 1;
    }

    unless ( sysread ( $file, $sindex, $sindex_len, 0 ) ) {
	prerror "Sysread error: $!";
	return q{};
    }
    
    if ( $class->{ compressor } eq COMPRESSOR_NONE ) {
	prinfo 'No decompression needed';
	$sindex_d = $sindex;

    }
    elsif ( $class->{ compressor } eq COMPRESSOR_GZIP ) {
	prinfo 'Decompressing short index using gzip';
	$sindex_d = uncompress ( $sindex, GZIP_COMPRESSION_LEVEL );

	unless ( $sindex_d ) {
	    prerror ("Decompression failed");
	    exit 1;
	}

    }
    elsif ( $class->{ compressor } eq COMPRESSOR_BZIP2 ) {
	prinfo 'Decompressing short index using bgzip2';
	$sindex_d = Compress::Bzip2::uncompress ( $sindex, GZIP_COMPRESSION_LEVEL );

	unless ( $sindex_d ) {
	    prerror ("Decompression failed");
	    exit 1;
	}
    }
    else {
	prerror 'Wrong compression';
	exit 1;
    }

    $i = 0;
    for ( @{ $class->{ words_list } } ) {
	$temp_index{ $_ } = $i++;
    }

    for ( $i=0; $i < $class->{ header }->{ sindex_total }; $i++ ) { 
	my $sword = substr (
			    $sindex_d,
			    $i * SINDEX_ITEM_LEN,
			    SDICT_SHORT_NDX_LEN * 4
			    );

	from_to ( $sword, "UTF-32LE", "utf8" );
	$sword_u = $sword;

	$sword_u =~ s|\x0||g;

	$word_ptr = unpack ( "L", substr ( $sindex_d,
					   $i * SINDEX_ITEM_LEN + SDICT_SHORT_NDX_LEN * 4,
					   4
					   )
			     );

	unless ( sysseek (
			  $file,
			  $class->{ header }->{ f_index_pos } + $word_ptr,
			  0
			  )
		 ) {
	    prerror "Seek error: $!";
	    exit 1;
	}

	unless ( sysread ($file, $fiunit, 2+2+4, 0 ) ) {
	    prerror "Sysread error: $!";
	    return q{};
	}

	my $len = unpack ( "S", substr( $fiunit, 0, 2 ) )
	    - 4 - 2 - 2;

	unless ( sysread ( $file, $word, $len, 0 ) ) {
	    prerror "Sysread error: $!";
	    return q{};
	}

	$sindex_words{ $sword_u } = $temp_index{ $word };
    }

    $class->{ sindex_hash } = \%sindex_words;

    # for (keys %sindex_words) { $_ = decode ("utf8", $_); print ">$_<\n"; } die;
    # print Dumper $class; die;

    return 1;
}


sub dump_all_words ($) {
    my $class = shift;
    my (
	$word,
	$fpos,
	$art
	);
    my $infile  = $class->{ infile_handler  };
    my $outfile = $class->{ outfile_handler };
    my $sep = SDICT_SOURCE_FILE_SEP_O;

    for $word ( @{ $class->{ words_list } } ) {

	$fpos = $class->{ words_hash }->{ $word } + $class->{ articles_pos };

	$art = $class->read_unit ( $fpos );

	if ( $art eq q{} ) {
	    prerror "Unable to read article for word '$word'";
	    exit 1;
	}

	print $outfile $word;
	print $outfile $sep;
	print $outfile $art;
	print $outfile "\n";
    }

    print $outfile "#\n# End of articles\n#\n";

    return 1;
}


sub read_unit ($$) {
    my ( $class, $fpos ) = @_[0,1];
    my $file = $class->{ infile_handler };
    my $unit = q{};
    my $val = q{};

    unless ( sysseek ( $file, $fpos, 0 ) ) {
	prerror "Seek error: $!";
	return q{};
    }

    unless ( sysread ( $file, $unit, 4, 0 ) ) {
	    prerror "Sysread error: $!";
	    return q{};
	}

    unless ( sysread (
		      $file,
		      $val,
		      unpack ("L", $unit),
		      0
		      )
	     ) {
	prerror "Sysread error: $!";
	return q{};
    }

    return ( decompress_unit ( $class, $unit . $val ) );
}


sub analyze ($) {
    my $class = shift;

    $class->{ outfile } = "temp-$$";

    prinfo 'Retrieving headers';
    exit 1 unless $class->get_infile_headers;

    prinfo 'Making header';
    exit 1 unless $class->create_header;

    prinfo 'Retrieving articles and making words hash';
    exit 1 unless $class->make_articles;

    prinfo 'Making full index';
    exit 1 unless $class->make_full_index;

    my ( $j, $mm );
    my %hh = ();

    if (! exists $class->{ analyze_max } ||
	$class->{ analyze_max } < 3      ||
	$class->{ analyze_max } > 15
	) {

	$mm = 3;
    }
    else {
	$mm = $class->{ analyze_max };
    }


    for ( $j=3; $j <=$mm; $j++ ) {
	$class->{ slevels } = $j;

	prinfo "Making short index for $j";
	exit 1 unless $class->make_short_index;

	my $ucs = $class->{ temp_si_file_size_unc };
	my $ccs = $class->{ temp_si_file_size };

	prinfo "Analyzing gap for $j";
	my $m = $class->analyze_gaps;

	$hh{$j} = "$ucs/$ccs $m";
    }

    prinfo 'Cleanups';
    unlink $class->{ outfile };
    exit 1 unless $class->cleanups;

    prinfo q{};
    prinfo q{};
    prinfo '*******************************************************';
    prinfo '***                   SUMMARY                       ***';
    prinfo '*******************************************************';
    prinfo "Dictionary: $class->{ header }->{ title }";
    $_ = scalar ( @{ $class->{ words_list } } );
    prinfo "Words: $_";
    prinfo q{};

    for (sort { $a<=>$b } keys (%hh) ) {
	prinfo "Sindex for $_ : $hh{$_}";
    }
    prinfo q{};
    prinfo '*******************************************************';

    return 1;
}


sub analyze_gaps ($) {
       my $class = shift;
       my $len = $class->{ slevels };

       my @words = @{ $class->{ words_list } };
       for (@words) {
	   $_ = decode ("utf8", $_);
       }

       my %h = ();

       for ( @words ) {
	   $_ = substr( $_, 0 , $len );
	   $h{$_}++;
       }

       my %h2 = reverse %h;

       my $i = 0;
       my $m = q{[ };
       for ( reverse ( sort { $a <=> $b } keys ( %h2 ) ) ) {
	   $m .= "$_/'$h2{$_}'; ";
	   last if ($i++ >3);
       }                                                                                        

       $m .= ']';

       prinfo $m;
       return $m;
}


sub compile ($) {
    my $class = shift;

    if ( $class->{ slevels } != 3 ) {
	prinfo 'Use non-standard short index levels value can cause incompatibility problems!';
	if ( -t STDIN && -t STDOUT ) {
	    {
		local $|=1;
		for ( my $i=0; $i<1; $i++ ) {
		    print "\a";
		    sleep 1;
		}
	    }
	}
    }

    prinfo 'Retrieving headers';
    exit 1 unless $class->get_infile_headers;

    prinfo 'Making header';
    exit 1 unless $class->create_header;

    prinfo 'Retrieving articles and making words hash';
    exit 1 unless $class->make_articles;

    prinfo 'Making full index';
    exit 1 unless $class->make_full_index;

    prinfo 'Making short index';
    exit 1 unless $class->make_short_index;

    prinfo 'Tunning header';
    exit 1 unless $class->correct_header;

    prinfo 'Joining files';
    exit 1 unless $class->join_files;

    prinfo 'Cleanups';
    exit 1 unless $class->cleanups;

    return 1;
}


sub get_infile_headers ($) {
    my $class = shift;
    my %h =();
    my $fl = 0;
    my $file = $class->{ infile };

    unless ( open F, "< $file" ) {
	prerror "Unable to open input file '$file': $!";
	return 0;
    }

    while (<F>) {
	chomp;
	s/\r$//;
	next if /^\#/;
	next if /^\s*$/;
	if (/^<header>/) { $fl=1; next; }
	last if (/^<\/header>/);
	next unless $fl;
	next unless /\s=\s/;
	my ($p,$v) = ( split ( /\s=\s/, $_, 2 ) )[0,1];
	$p=~s|^\s+||; $p=~s|\s+$||;
	$v=~s|^\s+||; $v=~s|\s+$||;
	next if ( ($p eq q{}) || ($v eq q{}) ); 
	$h{$p} = $v;
    }

    close F;

    unless (defined($h{'title'})) {
	prerror "Missing keyword 'title' in file '$file'";
	return 0;
    }

    unless (defined($h{'copyright'})) {
	prerror "Missing keyword 'copyright' in file '$file'";
	return 0;
    }

    unless (defined($h{'w_lang'})) {
	prerror "Missing keyword 'w_lang' in file '$file'";
	return 0;
    }

    unless (defined($h{'a_lang'})) {
	prerror "Missing keyword 'a_lang' in file '$file'";
	return 0;
    }

    unless (defined($h{'version'})) {
	prerror "Missing keyword 'version' in file '$file'";
	return 0;
    }


    $h{'w_lang'} = substr( $h{'w_lang'}, 0, 3 );
    $h{'a_lang'} = substr( $h{'a_lang'}, 0, 3 );

    if ( exists ( $h{ 'charset' } ) ) {
	unless ( grep /^$h{ 'charset' }$/, Encode->encodings (":all") ) {
	    prerror "Wrong charset '$h{ 'charset' }'";
	    print_available_charsets ();
	    return 0;
	}
	if ( $h{ 'charset' } eq 'utf8' ) {
	    delete $h{ 'charset' };
	}
    }

    if ( exists ( $h{ 'charset' } ) ) {
	from_to ( $h{ 'version'   }, $h{ 'charset' }, "utf8" );
	from_to ( $h{ 'copyright' }, $h{ 'charset' }, "utf8" );
	from_to ( $h{ 'title'     }, $h{ 'charset' }, "utf8" );
    }

    $class->{ header }=\%h;
    return 1;
}


sub print_available_charsets {
    prinfo 'Available charsets are:' ;
    @_ = sort ( Encode->encodings (":all") );
    prinfo @_;
}


sub create_header ($) {
    my $class=shift;

    my (
	$word_amount,
	$title_ptr,
	$copyright_ptr,
	$version_ptr,
	$short_ndx_ptr,
	$full_ndx_ptr,
	$articles_ptr,
	$sindex_amount
	);

    $word_amount = $title_ptr = $copyright_ptr = $short_ndx_ptr =
    $full_ndx_ptr = $articles_ptr = $sindex_amount = 0;

    my $title_unit     = create_unit( $class, $class->{ header }->{ title     } );
    my $copyright_unit = create_unit( $class, $class->{ header }->{ copyright } );
    my $version_unit   = create_unit( $class, $class->{ header }->{ version   } );

    my $w_lang = substr ( $class->{ header }->{ w_lang }, 0, 2 ) . pack ( "c", 0 );
    my $a_lang = substr ( $class->{ header }->{ a_lang }, 0, 2 ) . pack ( "c", 0 );

    $title_ptr = SDICT_HEADER_SIZE;
    $copyright_ptr = $title_ptr + length( $title_unit );
    $version_ptr = $copyright_ptr + length( $copyright_unit );
    $short_ndx_ptr = $version_ptr + length( $version_unit );

    my $co = hex ( $COMPRESSION{ $class->{ compressor } } ) & 0x0f;
    my $sl = $class->{ slevels };

    $sl = ( ($sl & 0x0f) << 4 ) & 0xf0;

    $sl = pack ( "C", ( $sl | $co ) );

    my $header =  SDICT_SIG . $w_lang . $a_lang . $sl .
	pack ("L8", $word_amount, $sindex_amount, $title_ptr, $copyright_ptr, $version_ptr,
	      $short_ndx_ptr, $full_ndx_ptr, $articles_ptr); 

    $class->{ header_file_size } =
	length ( $header         ) +
	length ( $title_unit     ) +
	length ( $copyright_unit ) +
	length ( $version_unit   );

    my $oufile = $class->{ outfile };

    prinfo "Writing header into file '$oufile'";

    unless ( open ( F, ">$oufile" ) ) {
	prerror "Unable to create file '$oufile': $!";
	exit 1;
    }

    binmode F;

    print F $header;
    print F $title_unit;
    print F $copyright_unit;
    print F $version_unit;
    close F;
    return 1;
}


sub correct_header ($) {
    my $class = shift;
    my $val = 0;

    unless ( sysopen ( HDR, $class->{ outfile }, O_RDWR ) ) {
	prerror "Unable to open file '", $class->{ outfile }, "':$!";
	exit 1;
    }

    unless ( sysseek( HDR, $WORDS_TOT_PTR_POS, 0 ) ) {
	prerror "Seek error: $!";
	exit 1;
    }
    else {
	$val = pack ( "L", $class->{ words_total } );
	syswrite (HDR, $val);
    }

    unless ( sysseek( HDR, $SINDEX_TOT_PTR_POS, 0 ) ) {
	prerror "Seek error: $!";
	exit 1;
    }
    else {
	$val = pack ( "L", $class->{ sindex_total } );
	syswrite (HDR, $val);
    }

    unless ( sysseek ( HDR, $SINDEX_PTR_POS, 0 ) ) {
	prerror "Seek error: $!";
	exit 1;
    }
    else {
	$val = pack ( "L", $class->{ header_file_size } );
	syswrite ( HDR, $val );
    }

    unless ( sysseek ( HDR, $FINDEX_PTR_POS, 0 ) ) {
	prerror "Seek error: $!";
	exit 1;
    }
    else {
	$val = pack (
		     "L",
		     $class->{ header_file_size } + $class->{ temp_si_file_size }
		     );

	syswrite ( HDR, $val );
    }

    unless ( sysseek ( HDR, $ARTICLES_PTR_POS, 0 ) ) {
	prerror "Seek error: $!";
	exit 1;
    }
    else {
	$val = pack (
		     "L",
		         $class->{ header_file_size  } +
		         $class->{ temp_si_file_size } +
		         $class->{ temp_fi_file_size }
		     );
	syswrite ( HDR, $val );
    }

    close HDR;
    return 1;

}


sub make_articles ($) {
    my $class = shift;
    my %words_hash = ();
    my %words_dups = ();
    my @words_list = ();
    my $oufile = $class->{ outfile };
    my $articles_total = 0;
    my $lines = 0;
    my $lines_skp = 0;
    my $lines_passed = 0;
    my $aliases = 0;

    my (
	$line,
	$word,
	$art,
	$alword,
	$aunit,
	);

    my $sep = SDICT_SOURCE_FILE_SEP;
    my $art_ptr = 0;


    if ( $class->{ lowercasealias } || $class->{ forcetolowercase } ) {

	eval 'use SdictUtils';

	if ( $@ ) {
	    prerror "Unable to load module 'SdictUtils' $@";
	    exit 1;
	}
    }

    my $temp_afile = $oufile . '-tmp1-' . $$;

    prinfo "Creating temporary file '$temp_afile'";
    unless ( open ( DF, ">$temp_afile" ) ) {
	prerror "Unable create file '$temp_afile':$!";
	return 0;
    }

    binmode DF;

    $class->{ temp_afile } = $temp_afile;

    my $infile = $class->{ infile };

    prinfo "Parsing source file '$infile'";

    unless ( open ( SF, "< $infile" ) ) {
	prerror "Unable open file '$infile': $!";
	return 0;
    }

    while (<SF>) {
	$lines++;
	chomp;
	s/\r$//;
	next if /^\#/         ;
	next if /^\s*$/       ;
	last if /^<\/header>/ ;
    }

    while (<SF>) {
	$lines++;
	chomp;
	s/\r$//;
	next if /^\#/   ;
	next if /^\s*$/ ;
	$line = $_;
	next unless ( /$sep/ );
	( $word, $art ) = ( split ( /$sep/, $line,2 ) )[0,1];

	if ( exists ( $class->{ header }->{ charset } ) ) {
	    from_to ( $word, $class->{ header }->{ charset }, "utf8" );
	    from_to ( $art,  $class->{ header }->{ charset }, "utf8" );
	}

	if ( ( $word eq q{} ) || ( $art eq q{} ) ) {
	    prerror "Skipped wrong  line at $lines '$line'";
	    $lines_skp++;
	    next;
	}

	if ( length ( $word ) > SDICT_WORD_MAX_SIZE) {
	    $word = substr ( $word, 0, SDICT_WORD_MAX_SIZE );
	    print "Truncated word at line $lines\n";
	}

	if ( length ( $art ) > SDICT_ART_MAX_SIZE ) {
	    $art = substr ($art, 0, SDICT_ART_MAX_SIZE );
	    print "Truncated art at line $lines\n";
	}

	$lines_passed++;
	$aunit = create_unit ( $class, $art );

	#
	# to lowercase
	#
	if ( $class->{ forcetolowercase } ) {

	    $word = utf8_lowercase ( decode ( "utf8", $word )  );

	    if ( $word eq q{} ) {
		prerror "Unable to lowercase word '$word'";
		return q{} ;
	    }

	    $word = encode ( "utf8", $word ) ;
	}

	#
	# Duplicates
	#
	if ( exists ( $words_hash{ $word } ) ) {
	    if ( $class->{ disableduplicates } ) {
		prerror "Duplicated word '$word'";
		return {} ;
	    }

	    $words_dups{ $word }++; # 1 - 2nd, 2 - 3rd and so on...
	    my $nname = $words_dups{ $word };
	    $nname++;
	    $word .= " ($nname)";
	}
	#
	# Store word
	#
	push ( @words_list, $word ); 
	$words_hash{ $word } = $art_ptr;

	$art_ptr += length ( $aunit );
	print DF $aunit;
        # print "L>$line<\n";
    }

    close SF;
    close DF;


    # lowercase aliases
    if ( $class->{ lowercasealias } ) {
	prinfo "Making lowercase aliases";

	for my $ww ( keys ( %words_hash ) ) { 

	    $alword = utf8_lowercase ( decode ( "utf8", $ww )  );

	    if ( $alword ne q{} ) {

		$alword = encode ( "utf8", $alword ) ;

		if ( ( $alword ne $ww ) && ( ! exists ( $words_hash{ $alword } ) ) ) {
		    push ( @words_list, $alword );
		    $words_hash{ $alword } = $words_hash{ $ww };
		    $aliases++;
		}
	    }
	}
    }
    #


    prinfo "Lines - total: $lines, skipped:$lines_skp, passed:$lines_passed";

    if ( $class->{ lowercasealias } ) {
	prinfo "Aliases created: $aliases";
    }

    $class->{ words_total } = $lines_passed;
    $class->{ words_list  } = \@words_list;
    $class->{ words_hash  } = \%words_hash;


    $class->sort_words_list if ( $class->{ sort } );

    return 1;
}


sub sort_words_list ($) {
    my $class = shift;
    prinfo 'Sorting word list';
    my @sorted = ();

    my @unsorted = @{ $class->{ words_list } };
    for (@unsorted) {
	$_ = decode ( "utf8", $_ );
    }

    if ( $class->{ sort } eq 'numeric') { # use numeric sorting

	prinfo "Using numeric sort method";

	@sorted  = sort { $a<=>$b } ( @unsorted );

    }
    elsif ( $class->{ sort } ne 'Unicode::Collate') { # use table sorting

	$sort_table_pl = $class->{ sort };
	$sort_table_pl .= '.pl' if ( $sort_table_pl !~ /\.pl$/ );

	prinfo "Using sort table from library '$sort_table_pl'";

	eval ("require '$sort_table_pl'");

	if ( $@ ) {
	    prerror "Unable to load .pl: '$@'";
	    exit 1;
	}

	eval ("use Sort::ArbBiLex;");

	if ( $@ ) {
	    prerror "Unable to load Sort::ArbBiLex: '$@'";
	    exit 1;
	}

	*my_sort = Sort::ArbBiLex::maker ( $sort_table );

	@sorted  = my_sort ( @unsorted );
    }
    else { # use Unicode::Collate sorting

	prinfo "Using Unicode::Collate for sorting";

	eval ("use Unicode::Collate;");

	if ( $@ ) {
	    prerror "Unable to load Unicode::Collate: '$@'";
	    exit 1;
	}

	my $collator = Unicode::Collate->new (
					      upper_before_lower => 1
					      );

	unless ( $collator ) {
	    prerror 'Unable create sorting collator';
	    exit 1;
	}

	@sorted = $collator->sort(@unsorted);

    }


    unless ( @sorted ) {
	prerror 'Unable sort';
	exit 1;
    }

    @unsorted = undef;
    for ( @sorted ) {
	$_ = encode ( "utf8", $_ );
    }

    $class->{ words_list } = undef;
    $class->{ words_list } = \@sorted;
    return 1;
}


sub sort_words_list_ ($) {
    my $class = shift;
    prinfo 'Sorting word list';

    my @unsorted = @{ $class->{ words_list } };
    for (@unsorted) {
	$_ = decode ( "utf8", $_ );
    }

    my $sorter = SortUTF8->new;

    unless ( $sorter->load_table ( 'latin-cyrillic.tbl' ) ) {
	prerror 'Unable create sorter';
	exit 1;
    }

    my @sorted = $sorter->sort ( @unsorted );

    unless ( @sorted ) {
	prerror 'Unable sort';
	exit 1;
    }

    @unsorted = undef;
    for ( @sorted ) {
	$_ = encode ( "utf8", $_ );
    }

    $class->{ words_list } = undef;
    $class->{ words_list } = \@sorted;
    return 1;
}


sub make_full_index ($) {
    my $class = shift;
    my $oufile = $class->{ outfile };
    my $temp_fi_file = $oufile . '-tmp2-' . $$;
    my $word;
    my $wl;
    my $i_prev = 0;
    my $i_next = 0;
    my $fpos   = 0;
    my $wunit  = q{};

    prinfo "Creating temporary file '$temp_fi_file'";
    unless ( sysopen ( FIF, $temp_fi_file, O_RDWR | O_CREAT ) ) {
	prerror "Unable create file '$temp_fi_file':$!";
	return 0;
    }

    $class->{ temp_fi_file } = $temp_fi_file;


    for $word ( @{ $class->{ words_list } } ) {
	$wl = length ( $word );
	$i_next = $wl + 4 + 2 + 2;
	$wunit = pack (
		       "S2L",
		       $i_next,
		       $i_prev,
		       $class->{ words_hash }->{ $word }
		       )
	    . $word;

	$fpos = sysseek( FIF, 0, 1 );
	syswrite ( FIF, $wunit );
	$i_prev = $i_next;
    }

    # lead out
    $wunit = pack ( "S2L", 0, $i_prev, 0 );
    syswrite ( FIF, $wunit );

    close FIF;

    $class->{ temp_fi_file      } = $temp_fi_file;    
    $class->{ temp_fi_file_size } = ( stat ( $temp_fi_file ) )[7];    

    return 1;
}


sub make_short_index ($) {
    my $class = shift;

    my $oufile = $class->{ outfile };
    my $temp_si_file = $oufile . '-tmp3-' . $$;

    my $fpos         = 0;
    my $last_s_index = q{};
    my %all_s_ndx    = ();
    my $sindex_total = 0;

    my (
	$record,
	$cur_word_len,
	$cur_word_p,
	$cur_word,
	$cur_word_p_sub,
	$cur_word_sub,
	$extend,
	$unit,
	$i, 
	%words_hash_short,
	@words_list_short,
	$j,
	%words_hash,
	@words_list
	);

    prinfo "Creating temporary file '$temp_si_file'";

    unless  ( open ( SIF, "> $temp_si_file" ) ) {
	prerror "Cannot create $temp_si_file:$!";
	exit 1;
    }

    binmode SIF;

    unless ( sysopen( IF, $class->{ temp_fi_file }, O_RDONLY ) ) {
	prerror "Unable open file '", $class->{ temp_fi_file }, "':$!";
	exit 1;
    }

#
# reading all words from full index
#

    %words_hash = ();
    @words_list = ();

    while (1) {
	$fpos = sysseek( IF, 0, 1 );

	unless ( sysread ( IF, $record, 8, 0 ) ) {
	    prinfo "Looks like EOF";
	    last;
	}
    
	$cur_word_len = ( unpack (
				  "S",
				  substr ( $record, 0, 2 ) 
				  )
			  )[0];

	unless ($cur_word_len) {
	    prinfo "Last record, quit";
	    last;
	}
    
	sysread (
		 IF,
		 $cur_word,
		 $cur_word_len - 8
		 );

	$cur_word_p = decode ( "utf8", $cur_word );

	push ( @words_list, $cur_word_p );
	$words_hash{$cur_word_p} = $fpos;
        # print ">>$cur_word_p<<   >>$fpos<< \n";
    }

#
# Making indices
#
    %words_hash_short = ();
    @words_list_short = ();

    my $slev_total = $class->{ slevels };

    prinfo "Short index levels: $slev_total";

    for ( $i = 1; $i <= $slev_total; $i++ ) {

	prinfo "Making with length $i";

	for $j ( @words_list ) {

	    $cur_word_p_sub = substr ( $j, 0, $i );

	    if ( exists ( $words_hash_short{ $cur_word_p_sub } ) ) {
		$words_hash_short{ $cur_word_p_sub }++;
		#prinfo "index '$cur_word_p_sub' already exists, skip";
		next;
	    }

	    $words_hash_short{ $cur_word_p_sub }++;
	    $fpos = $words_hash{ $j };

	    $cur_word_sub = encode( "utf8", $cur_word_p_sub );
            # $cur_word_sub = $cur_word_p_sub;

	    push ( @words_list_short, $cur_word_sub ); 

            # $cur_word_sub = $cur_word_p_sub;
	    from_to ( $cur_word_sub, "utf8",  "UTF-32LE" );

	    $extend = q{};

	    if ( length ( $cur_word_p_sub ) < $slev_total ) {
		for (
		     my $i=0;
		     $i < ($slev_total - length($cur_word_p_sub));
		     $i++ ) {
		    $_ = pack( "L", 0 );
		    $extend .= $_;
		}
	    }

	    $unit = $cur_word_sub . $extend . pack ( "L", $fpos );
	    #$_ = length ($unit); print "L>$_<\n";

	    print SIF $unit;
	    $sindex_total++;
	}
    }

    close SIF;
    close IF;

    
    $class->{ temp_si_file_size_unc } = ( stat ( $temp_si_file ) )[7];    
    $class->compress_s_index( $temp_si_file );

    $class->{ sindex_total      } = $sindex_total;
    $class->{ temp_si_file      } = $temp_si_file;    
    $class->{ temp_si_file_size } = ( stat ( $temp_si_file ) )[7];    

    my $ucs = $class->{ temp_si_file_size_unc };
    my $ccs = $class->{ temp_si_file_size     };

    prinfo "Short index info:  $ucs / $ccs";

    if ( $ucs > SDICT_SINDEX_WARN ) {
	#prinfo 'WARN! sindex too big';
    }

    return 1;
}


sub join_files ($) {
    my $class = shift;
    my $ofile = $class->{ outfile };
    my $file;

    $file = $class->{ temp_si_file };
    prinfo "Merging '$file' into '$ofile'";
    Sdict::Utils::merge ($file, $ofile);

    $file = $class->{ temp_fi_file };
    prinfo "Merging '$file' into '$ofile'";
    Sdict::Utils::merge ($file, $ofile);

    $file = $class->{ temp_afile };
    prinfo "Merging '$file' into '$ofile'";
    Sdict::Utils::merge ($file, $ofile);

    return 1;
}


sub cleanups ($) {
    my $class = shift;

    prinfo "Removing '", $class->{ temp_afile }, "'";
    unlink ( $class->{ temp_afile } );

    prinfo "Removing '", $class->{ temp_fi_file }, "'";
    unlink ( $class->{ temp_fi_file } );

    prinfo "Removing '", $class->{ temp_si_file }, "'";
    unlink ( $class->{ temp_si_file } );

    return 1;
}


sub create_unit ($$) {
    my ( $class, $text ) = @_[0,1];

    my $unit  = q{};
    my $ctext = q{};


    if ( $class->{ compressor } eq COMPRESSOR_NONE ) {
	$unit = pack ( "L", length( $text ) );
	$unit .= $text;
	return $unit;

    }
    elsif ( $class->{ compressor } eq 'gzip' ) {
	$ctext = compress ( $text, GZIP_COMPRESSION_LEVEL );
	$unit = pack ( "L", length ( $ctext ) );

	unless ( $ctext ) {
	    prerror ("Compression failed for '$text'");
	    exit 1;
	}

	$unit .= $ctext;
	return $unit;

    }
    elsif ( $class->{ compressor } eq 'bzip2' ) {

	$ctext =  Compress::Bzip2::compress ( $text, BZIP2_COMPRESSION_LEVEL );
	$unit = pack ( "L", length($ctext ) );

	unless ( $ctext ) {
	    prerror ("Compression failed for '$text'");
	    exit 1;
	}

	$unit .= $ctext;
	return $unit;
    }


    prerror 'Unsupported compression method';
    exit 1;
}


sub decompress_unit ($$) {
    my ( $class, $unit ) = @_[0,1];
    my $text  = q{};
    my $ctext = q{};

    if ( $class->{ compressor } eq COMPRESSOR_NONE ) {
	$text = substr ( $unit, 4 );
	return $text;

    }
    elsif ( $class->{ compressor } eq COMPRESSOR_GZIP ) {
	$ctext = substr ( $unit, 4 );
	$text = uncompress ( $ctext );
	return $text;

    }
    elsif ( $class->{ compressor } eq COMPRESSOR_BZIP2 ) {
	$ctext = substr ( $unit, 4 );
	$text = Compress::Bzip2::uncompress ( $ctext );
	return $text;
    }

    prerror 'Wrong compression type';
    exit 1;

}


sub compress_s_index ($$) {
    my ( $class, $file ) = @_[0,1];
    local $/ = undef;
    my $content = q{};
    my $content_c = q{};

    prinfo "Compressing file '$file'";

    if ( $class->{ compressor } eq COMPRESSOR_NONE ) {
	prinfo "No compressing needed'";
	return 1;
    }
    elsif ( $class->{ compressor } eq COMPRESSOR_GZIP ) {
	unless ( open F, "< $file" ) {
	    prerror "Unable open file '$file':$!";
	    exit 1;
	}
	binmode F;

	$content = <F>;
	close F;

	unless ( length ( $content ) ) {
	    prerror "Zero file length";
	    exit 1;
	}

	prinfo "Short index uncompressed", length ( $content ), "byte(s)";

	$content_c = compress ( $content, GZIP_COMPRESSION_LEVEL );

	unless ( length( $content_c ) ) {
	    prerror "Compression failed";
	    exit 1;
	}

	prinfo "Short index compressed", length ( $content_c ), "byte(s)";

	unless ( open F, "> $file" ) {
	    prerror "Unable open file for writing '$file':$!";
	    exit 1;
	}
	binmode F;

	print F $content_c;
	close F;

	return 1;

    }
    elsif ( $class->{ compressor } eq COMPRESSOR_BZIP2 ) {
	unless ( open F, "< $file" ) {
	    prerror "Unable open file '$file':$!";
	    exit 1;
	}

	$content = <F>;
	close F;
	
	unless ( length($content ) ) {
	    prerror "Zero file length";
	    exit 1;
	}

	prinfo "Short index uncompressed", length ( $content ), "byte(s)";

	$content_c = Compress::Bzip2::compress ( $content, BZIP2_COMPRESSION_LEVEL );

	unless ( length($content_c ) ) {
	    prerror "Compression failed";
	    exit 1;
	}

	prinfo "Short index compressed", length ( $content_c ), "byte(s)";

	unless ( open F, "> $file" ) {
	    prerror "Unable open file for writing '$file':$!";
	    exit 1;
	}

	print F $content_c;
	close F;

	return 1;
    } 

    return 0;
}


package Sdict::Utils;

use constant {

    BUFFER_SIZE => 10240 ,
};

sub merge  {
    my ($file, $ofile) = @_;

    unless (open (IF, "< $file")) {
	Sdict::prerror "can't open file $file: $!";
	exit 1;
    }

    unless (open (OF, ">> $ofile")) {
	Sdict::prerror "can't open file $ofile: $!";
	close (IF);
	exit 1;
    }

    binmode (IF);
    binmode (OF);

    my $buf = q{};
    my $rlen = 0;

    while ( ($rlen = read (IF, $buf, BUFFER_SIZE)) ) {
	print OF $buf;
	$buf = q{};
    }

    close (IF);
    close (OF);
}

1;


__END__

=cut

=head1 NAME

Sdict - Module to work with Sdictionary .dct files

=head1 SYNOPSIS

	use Sdict;


    # File compilation/decompilation
	$Sdict::debug = 1;

	$sd = Sdict->new;

	$sd->parse_args;

	$sd->analyze;

	$sd->convert;

	exit;


    # Working with .dct
	$sd = Sdict->new;

	$sd->debug_on; # or $sd->debug_off;

	$sd->init ( { file => 'test.dct' } );

    # Load dictionary
	unless ($sd->load_dictionary_fast) {
	    die 'Unable load dictionary';
	}


    # Locate word
        my $article = $sd->search_word ('fox');
        print "translation is '$article'\n" if $article;


    # Unload dictionary
	$sd->unload_dictionary;


    # If you are interested about header only
        unless ($sd->read_header) {
            die 'Unable to load dictionary';
            next;
        }

        warn "found '$sd->{header}->{title}'";


    # Information about dictionary
        $title = $sd->{header}->{title};
	$copyright = $sd->{header}->{copyright};
	$word_lang = $sd->{header}->{w_lang};
	$article_lang = $sd->{header}->{a_lang};
	$version = $sd->{header}->{version};
	$words_total = $sd->{header}->{words_total};


    # Print info
	$sd->print_dct_info;



    # Get words from current position
	for (my $i=0; $i < SDICT_LOAD_ITEMS; $i++) {

        	$word = $sd->get_next_word;
		$word = decode ("utf8", $word);

	        last if ($curWord eq q{}); # Last word reached

		warn "word '$word'";

		...
	}

	$pos = $sd->{f_index_pos_cur};


    # Get previous word
	$word = $sd->get_prev_word;


    # Get article you stay on
	$article = $sd->read_unit($sd->{cur_word_pos} + $sd->{articles_pos});


=head1 AUTHOR

The I<Sdict> module was written by Alexey Semenoff,
F<swaj@swaj.net> as part of Sdictionary project. The project homepage is
http://freshmeat.net/projects/sdictionary/.

=head1 MODIFICATION HISTORY

See the Changes file.
