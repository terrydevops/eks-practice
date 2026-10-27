#!/bin/sh
# git clean/smudge filter: placeholders in git, real values in the working tree.
#   clean  (commit):   real value  -> __KEY__
#   smudge (checkout): __KEY__     -> real value
# Values come from local.env at the repo root. Without it, content passes through.
mode="$1"
env_file="$(git rev-parse --show-toplevel)/local.env"
[ -f "$env_file" ] || exec cat
exec perl -e '
  my ($mode, $file) = @ARGV; @ARGV = ();
  open my $fh, "<", $file or die "$file: $!";
  my @kv;
  while (<$fh>) { chomp; next if /^\s*(#|$)/; my ($k, $v) = split /=/, $_, 2; push @kv, [$k, $v] if length $v; }
  # longest value first so GIT_REPO_URL wins over GITLAB_PROJECT
  @kv = sort { length($b->[1]) <=> length($a->[1]) } @kv;
  local $/; my $s = <STDIN>;
  for (@kv) { my ($k, $v) = @$_;
    if ($mode eq "clean") { $s =~ s/\Q$v\E/__${k}__/g } else { $s =~ s/__\Q$k\E__/$v/g } }
  print $s;
' "$mode" "$env_file"
