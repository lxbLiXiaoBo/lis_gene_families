#!/usr/bin/env perl


#use strict
use warnings;
use Getopt::Long; # get the command line options
use Pod::Usage; # so the user knows what's going on
use DBI; # our DataBase Interface


=head1 Name

 gmod_load_msa.pl - Loads multiple sequence alignment data into the database.

=head1 SYNOPSIS

  gmod_load_msa.pl <msa_file> [options]

  --dbname          The name of the chado database (default=chado)
  --username        The username to access the database with (default=chado)
  --password        The password to log into the database with
  --host            The host the database is on (default=localhost)
  --port            The port the database is on
  --dbid            The db_id from the db table for the db that the msa feature should have a dbxref with.
  --consensus_name  The value given to the name and uniquename fields of the feature for the msa
  --check_exists    Will use a consensus feature with the given consensus name if it exists
  --errorfile       The file that errors should be written to (defailt=gmod_load_msa_errors.txt)

=head1 DESCRIPTION

The only argument to the script is the input file that contains the multiple sequence alignment. Polypeptide names in the database have "_pep" appeneded to their names to distinguish them from their mRNA. It follows that the names of sequences represented in the input file may have "_pep" appended to the end as well, though, this is not necessary.

The --concensus_name flag is required as well. This is the value given to the name and uniquename fields for the multiple sequence alignment feature. Note that the value given must not already exist in the table since it is used as the value for the features uniquename field.

The --check_exists flag should be used with caution. Before creating a new feature for the consensus, it checks to see if one already exists and uses it if it does. This can be useful if a load was cancelled partway through and not all the featureloc entries were created. Likewise, featureloc entries can be created for a consensus they don't belong to.

Note that this script requires there to be a "consensus" organism in the database. All fields of the organism should have "consensus" as their value.

=head1 AUTHOR

Alan Cleary

Copyright (c) 2013
This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut


# see if the user needs help
my $man = 0;
my $help = 0;
GetOptions('help|?' => \$help, man => \$man) or pod2usage(2);
pod2usage(1) if $help;
pod2usage(-exitval => 0, -verbose => 2) if $man;


# get the command line options and environment variables
my ($port, $concensus, $db, $exists);
$port = $ENV{CHADO_DB_PORT} if ($ENV{CHADO_DB_PORT});
my $dbname = "chado";
$dbname = $ENV{CHADO_DB_NAME} = ($ENV{CHADO_DB_NAME});
my $username = "chado";
$username = $ENV{CHADO_DB_USER} if ($ENV{CHADO_DB_USER});
my $password = "";
$password = $ENV{CHADO_DB_PASS} if ($ENV{CHADO_DB_USER});
my $host = "localhost";
$host = $ENV{CHADO_DB_HOST} if ($ENV{CHADO_DB_HOST});
my $errorfile = "gmod_load_msa_errors.txt";

GetOptions("dbname=s"           => \$dbname,
           "username=s"         => \$username,
           "password=s"         => \$password,
           "host=s"             => \$host,
           "port=i"             => \$port,
           "consensus_name=s"   => \$consensus_name,
           "check_exdists"      => \$exists,
           "dbid=i"             => \$db,
           "errorfile=s"        => \$errorfile) || die("Error in command line arguments\n");

if (!$consensus_name) {
    die("The --consensus_name flag is required\n");
}


# make sure there weren't any unexpected command line arguments
if (@ARGV != 1) {
    pod2usage(2);
}


# open the msa file
print "Opening input file\n";
open(FILE, $ARGV[0]) || die("Failed to read the input file\n");


# create a data source name
print "Connecting to database\n";
my $dsn = "dbi:Pg:dbname=$dbname;host=$host;";
$dsn .= "port=$port;" if $port;


# connect to the database
my $conn = DBI->connect($dsn, $username, $password, {'RaiseError' => 1});


# get the cvterm for polypeptide
print "Retrieving polypeptide cvterm\n";
my $peptide = $conn->selectrow_array("SELECT cvterm_id FROM cvterm WHERE name SIMILAR TO 'polypeptide';");
if (!$peptide) {
    die("Failed to retrieve the polypeptide cvterm from the database\n");
}


# get the cvterm for consensus
print "Retrieving multiple sequence alignment cvterm\n";
my $msa = $conn->selectrow_array("SELECT cvterm_ID FROM cvterm WHERE name SIMILAR TO 'consensus';");
if (!$msa) {
    die("Failed to retrieve the consensus cvterm from the database\n");
}


# get the consensus organism
print "Retreiving consensus organism\n";
my $organism = $conn->selectrow_array("SELECT organism_id FROM organism WHERE genus='consensus' AND species='consensus';");
if (!$organism) {
    die("Failed to retriece the consensus organism from the database\n");
}


# get all the polypeptides from the file
my %peps = ();
while (my $line = <FILE>) {
    chomp $line;
    # skip the line if it's not a description line
    if (index($line, ">") != -1) {
        # trim any whitespace from the end of the string
        $line =~ s/\s*$//;
        $line .= "_pep" if (index($line, "_pep") == -1);
        $peps{substr($line, 1)} = 1; # 1 is a placeholder
    }
}
my $num_peps = scalar(keys(%peps));


# construct the query to get the polypeptide features
my $query_string = "SELECT feature_id, uniquename FROM feature WHERE";
my $i = 0;
for my $key (keys(%peps)) {
    print "key: ", $key, "\n";
    $i++;
    $query_string .= " uniquename='$key'";
    $query_string .= " OR" if ($i != $num_peps);
}
$query_string .= ";";
my $query = $conn->prepare($query_string);
$query->execute();


# see if all the polypeptides are in the databasee
print "rows: ", $query->rows, " peps: ", $num_peps, "\n";
if ($query->rows != $num_peps) {
    # open the error file
    print "Some polypeptides were missing\nOpening the error file\n";
    open(ERRORS, '>'.$errorfile) || die("Failed to open the error file: $!\n");
    print "Writing errors\n";
    print ERRORS "Failed to find polypeptides with uniquename:\n";
    # remove polypeptides that were found from the hash
    while (my @row = $query->fetchrow_array()) {
        my ($feature_id, $uniquename) = @row;
        delete $peps{$uniquename};
    }
    # report polypeptides that weren't found
    for my $key (keys(%peps)) {
        print ERRORS "", substr($key, 0, index($key, "_pep")), "\n";
    }
    # clode file and connection
    print "Closing error file\n";
    close(ERRORS);
    undef($query);
    $conn->disconnect();
    # die
    die("Exiting...\n");
}
# if not copy all their polypeptides respective feature_ids
while (my @row = $query->fetchrow_array()) {
    my($feature_id, $uniquename) = @row;
    $peps{$uniquename} = $feature_id; # no need to look them up twice
}


# create the consensus feature and get it's feature_id
print "Creating feature for consensus\n";

# here we can see if the desired consensus feature already exists just in case a load was cancelled before completeion...
# the uniqueness requirements of featureloc should prevent duplicates... should
# also, you could add more featurelocs to an existing msa if the name you provide is not unique. be careful!
$consensus_name .= "-consensus" if (index($consensus_name, "-consensus") == -1);
my $consensus;
if ($exists) {
    $consensus = $conn->selectrow_array("SELECT feature_id FROM feature WHERE name='$consensus_name' AND uniquename='$consensus_name';");
}
if (!$consensus) {
    if (!$conn->do("INSERT INTO feature (organism_id, name, uniquename, type_id) VALUES ($organism, '$consensus_name', '$consensus_name', $msa);")) {
        die("Failed to isnert consensus feature into the feature table\n");
    }
    $consensus = $conn->selectrow_array("SELECT feature_id FROM feature ORDER BY feature_id DESC;");
}


# create a variable to hold the current name
print "Creating alignment structure and inserting residues\n";
my $name;
# create a rank to featureloc uniqueness requirement
my $rank = 0;
# read the file one line at a time
close(FILE);
open(FILE, $ARGV[0]) || die("Failed to read the input file\n");
while (my $line = <FILE>) {
    chomp $line;
    # skip the line if it's a comment line
    if ($line =~ /^\#/) {
        next;
    }
    # if it's a description line then get the name
    elsif (index($line, ">") != -1) {
        $name = substr($line, 1);
        $name .= "_pep" if (index($name, "_pep") == -1);
    }
    # it must be a residue so add it
    else {
        $rank++;
        my $fmax = length($line);
        if(!$conn->do("INSERT INTO featureloc (feature_id, srcfeature_id, fmin, fmax, residue_info, rank) VALUES ($peps{$name}, $consensus, 0, $fmax, '$line', $rank);")) {
            print "Failed to create featureloc for feature $peps{$name} with src $consensus\n";
        }
    }
}


# close all the open stuff
print "Exiting\n";
$conn->disconnect();
close(FILE);

