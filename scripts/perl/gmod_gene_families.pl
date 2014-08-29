#!/usr/bin/env perl


use strict;
use warnings;
use Getopt::Long; # get the command line options
use Pod::Usage; # so the user knows what's going on
use DBI; # our DataBase Interface
use Cwd 'abs_path'; # for executing the indexing script


=head1 NAME

gmod_gene_families.pl - Adds an entry in the featureprop table in a chado database for each each family a gene belongs to.

=head1 SYNOPSIS

  gmod_gene_families.pl [options]

  --nuke        Delete all previous gene family entries in featureprop
  --dbname      The name of the chado database (default=chado)
  --username    The username to access the database with (default=chado)
  --password    The password to log into the database with
  --host        The host the database is on (default=localhost)
  --port        The port the database is on

=head1 DESCRIPTION

This script will finds all the phylogenetic trees (families) each gene in the database is associate with and creates an entry for each in the featureprop table.

If the --nuke flag is provided all previous gene family entries in the featureprop table wilol be removed before new ones are inserted.

If an entry already exists in the featureprop table for a gene and a tree a new entry will not be made.

=head1 AUTHOR

Alan Cleary

Copyright (c) 2014
This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut



# see if the user needs help
my $man = 0;
my $help = 0;
#GetOptions('help|?' => \$help, man => \$man) or pod2usage(2);
pod2usage(1) if $help;
pod2usage(-exitval => 0, -verbose => 2) if $man;

# get the command line options and environment variables
my ($port);
$port = $ENV{CHADO_DB_PORT} if ($ENV{CHADO_DB_PORT});
my $dbname = "chado";
$dbname = $ENV{CHADO_DB_NAME} if ($ENV{CHADO_DB_NAME});
my $username = "chado";
$username = $ENV{CHADO_DB_USER} if ($ENV{CHADO_DB_USER});
my $password = "";
$password = $ENV{CHADO_DB_PASS} if ($ENV{CHADO_DB_USER});
my $host = "localhost";
$host = $ENV{CHADO_DB_HOST} if ($ENV{CHADO_DB_HOST});
my $nuke = 0;

GetOptions("nuke|?"             => \$nuke,
           "dbname=s"           => \$dbname,
           "username=s"         => \$username,
           "password=s"         => \$password,
           "host=s"             => \$host,
           "port=i"             => \$port) || Retreat("Error in command line arguments\n");


# create a data source name
print "Connecting to the database\n";
my $dsn = "dbi:Pg:dbname=$dbname;host=$host;";
$dsn .= "port=$port;" if $port;

# connect to the database
my $conn = DBI->connect($dsn, $username, $password, {AutoCommit => 0, RaiseError => 1});
my $query;



# a subroutine to call when things get ugly
sub Retreat {
    print "Something went wrong.\nRolling back changes\n";
    eval{ $conn->rollback() } or print "Failed to rollback changes\n";
    Disconnect();
    die( $_[0] );
}

# close the connection
sub Disconnect {
    undef($query);
    $conn->disconnect();
}

print "Fetching preliminaries\n";

my $query_string;
# get the gene lis_properties cv from the database
my $cv_id = $conn->selectrow_array("SELECT cv_id FROM cv WHERE name='LIS_properties' LIMIT 1;");
# does it exist?
if( !$cv_id ) {
    $query_string = "INSERT INTO cv (name) VALUES ('LIS_properties');";
    if ( !$conn->do($query_string) ) {
        Retreat("Failed to add an entry into the cv table  for LIS_properties\n");
    }
    $cv_id = $conn->selectrow_array("SELECT cv_id FROM cv WHERE name='LIS_properties' LIMIT 1;");
}

# get the dbxref entry for gene family
my $dbxref_id = $conn->selectrow_array("SELECT dbxref_id FROM dbxref WHERE accession='gene_family' LIMIT 1;");
# does it exist?
if( !$dbxref_id ) {
    # does the db entry for ncgr exist?
    my $db_id = $conn->selectrow_array("SELECT db_id FROM db WHERE name ilike 'NCGR' LIMIT 1;");
    if( !$db_id ) {
        $query_string = "INSERT INTO db (name) VALUES ('NCGR');";
        if ( !$conn->do($query_string) ) {
            Retreat("Failed to add an entry into the db table  for NCGR\n");
        }
        $db_id = $conn->selectrow_array("SELECT db_id FROM db WHERE name='NCGR' LIMIT 1;");
    }
    $query_string = "INSERT INTO dbxref (db_id, accession) VALUES ($db_id, 'gene_family');";
    if ( !$conn->do($query_string) ) {
        Retreat("Failed to add an entry into the dbxref table to gene_family\n");
    }
    $dbxref_id = $conn->selectrow_array("SELECT dbxref_id FROM dbxref WHERE accession='gene_family' LIMIT 1;");
}

# check to see if there's a cvterm for gene families in the database
my $gene_family_id = $conn->selectrow_array("SELECT cvterm_id FROM cvterm WHERE name='gene family' LIMIT 1;");
# does it exist?
if ( !$gene_family_id ) {
    $query_string = "INSERT INTO cvterm (cv_id, name, definition, dbxref_id) VALUES ($cv_id, 'gene family', 'Links a gene to a phylogenetic tree one of its polypeptides is a member of.', $dbxref_id);";
    if ( !$conn->do($query_string) ) {
        Retreat("Failed to add feature to database\n");
    }
    $gene_family_id = $conn->selectrow_array("SELECT cvterm_id FROM cvterm WHERE name='gene family' LIMIT 1;");
}


# nuke the old featureprop entries... if we're supposed to
if( $nuke ) {
    print "Deleting old entries\n";
    $query_string = "SELECT featureprop_id FROM featureprop WHERE type_id=$gene_family_id;";
    $query = $conn->prepare($query_string);
    $query->execute();
    if( $query->rows() > 0 ) {
        my $delete_query = "DELETE FROM featureprop WHERE featureprop_id IN (";
        while( my @featureprop = $query->fetchrow_array() ) {
            my ($featureprop_id) = @featureprop;
            $delete_query .= $featureprop_id . ",";
        }
        $query_string = substr($query_string, 0, -1) . ");";
        $query = $conn->prepare($query_string);
        $query->execute();
    }
}

# get all the phylotree from the database
$query_string = "SELECT phylotree_id FROM phylotree WHERE name!='NCBI taxonomy tree';";
$query = $conn->prepare($query_string);
$query->execute();
# get all the genes for each tree and add an entry into the featureprop table
while( my @tree = $query->fetchrow_array() ) {
    my ($tree_id) = @tree;
    print "Adding entries for tree $tree_id\n";
    # get the peptide ids
    $query_string = "SELECT DISTINCT feature_id FROM phylonode WHERE phylotree_id=$tree_id;";
    my $peptide_query = $conn->prepare($query_string);
    $peptide_query->execute();
    print "    num peptides: " . $peptide_query->rows() . "\n";
    if( $peptide_query->rows() == 0 ) {
        next;
    }
    # get the mrna ids
    $query_string = "SELECT DISTINCT object_id FROM feature_relationship WHERE subject_id IN (";
    while( my @peptide = $peptide_query->fetchrow_array() ) {
        my ($peptide_id) = @peptide;
        $query_string .= $peptide_id . "," if( $peptide_id);
    }
    $query_string = substr($query_string, 0, -1) . ");";
    my $mrna_query = $conn->prepare($query_string);
    $mrna_query->execute();
    if( $mrna_query->rows() == 0 ) {
        next;
    }
    # get the gene ids
    $query_string = "SELECT DISTINCT object_id FROM feature_relationship WHERE subject_id IN (";
    while( my @mrna = $mrna_query->fetchrow_array() ) {
        my ($mrna_id) = @mrna;
        $query_string .= $mrna_id . ",";
    }
    $query_string = substr($query_string, 0, -1) . ");";
    my $gene_query = $conn->prepare($query_string);
    $gene_query->execute();
    if( $gene_query->rows() == 0 ) {
        next;
    }
    # add an entry to the featureprop table for each gene
    my $insert_featureprop = $conn->prepare("INSERT INTO featureprop (feature_id, type_id, value, rank) VALUES(?, $gene_family_id, '$tree_id', ?);");
    while( my @gene = $gene_query->fetchrow_array() ) {
        my ($gene_id) = @gene;
        my $featureprop_id = $conn->selectrow_array("SELECT featureprop_id FROM featureprop WHERE feature_id=$gene_id AND value='$tree_id' AND type_id=$gene_family_id LIMIT 1;");
        # does it exist?
        if ( !$featureprop_id ) {
            my $max_rank = $conn->selectrow_array("SELECT max(rank) FROM featureprop WHERE feature_id=$gene_id AND type_id=$gene_family_id;");
            if( !( defined $max_rank ) ) {
                $insert_featureprop->execute($gene_id, 0);
            } else {
                $insert_featureprop->execute($gene_id, $max_rank+1);
            }
        }
    }
}


print "Committing changes\n";
eval{ $conn->commit() } or Retreat("The commit failed\n");
Disconnect();



