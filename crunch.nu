use std log

const CACHE_DIR = "crunch-cache"
const RELEASES_JSON_PATH = ([$CACHE_DIR "releases.json"] | path join)

def dl-cached [
	--file: path,
	--url: string,
] {
	if ($file | path exists) {
		log debug $"Cache entry for `($file)` already exists, skipping download"
	} else {
		log debug $"Populating `($file)` from <($url)>…"
		mkdir ($file | path dirname)
		try {
			http get $url o> $file
		} catch {
			error make {
				msg: $"failed to request <($url)> via HTTP GET",
				label: {
					text: "failed to download this URL",
					span: (metadata $url).span
				}
			}
		}
	}
	$file
}

export def "dl-versions" [
	...crates: string,
] {
	$crates | each {|crate|
		dl-cached --file $"($CACHE_DIR)/versions/($crate).json" --url $'https://index.crates.io/($crate | str substring 0..1)/($crate | str substring 2..3)/($crate)'
	}
}

export def "list-versions" [
	...files: path,
] {
	$files | reduce --fold [] {|file, acc|
		$acc | append (open --raw $file | from json --objects)
	}
}

export def "dl-tarball" [
	name: string,
	version: string,
] {
	dl-cached --file $'($CACHE_DIR)/packages/($name)-($version).crate' --url $'https://crates.io/api/v1/crates/($name)/($version)/download'
}

export def "populate-cache" [
	...crates: string,
	--releases-path: path = $RELEASES_JSON_PATH,
	# Overrides the path to the releases database.
] {
	let version_index_files = dl-versions ...$crates
	let crate_version_table = list-versions ...$version_index_files | select name vers
	let crate_tarballs = $crate_version_table | insert tarball {|crate|
		dl-tarball $crate.name $crate.vers
	}
	let crate_version_commits = $crate_tarballs | insert commit {|crate|
		let extracted_dir = $'($CACHE_DIR)/packages-extracted'
		let dir = $'($extracted_dir)/($crate.name)-($crate.vers)'

		if ($dir | path exists) {
			log debug "Cache entry for `($dir)` existing, skipping archive extraction…"
		} else {
			log debug "Decompressing `($crate.tarball)` into `($dir)`…"
			ouch decompress --format tar.gz $crate.tarball --dir $extracted_dir
		}
		let vcs_info = $'($dir)/.cargo_vcs_info.json'
		try {
			let vcs_info_json_path = ls $vcs_info | get name | first
			open $vcs_info_json_path | get git | get sha1
		} catch {
			null
		}
	} | reject tarball
	# TODO: Get the repo. URL reported in `Cargo.toml`

	$crate_version_commits
		| group-by commit
		| transpose
		| rename commit releases
		| update releases { reject commit }
		| save --force $releases_path
}

export def "read-releases" [
	--releases-path: path = $RELEASES_JSON_PATH,
	# Overrides the path to the releases database.

	...crates: string,
] {
	open $releases_path
		| where {
			$in.releases | any { $in.name in $crates }
		}
		| update releases {
			$in | where name in $crates
		}
}

# Tag a local Git repo with tags of the form `{crate}-v{version}`.
export def "tag" [
	...crates: string,

	--repo-path: directory,
	# The directory containing the Git repository to be tagged.

	--releases-path: path = $RELEASES_JSON_PATH,
	# Overrides the path to the releases database.

	--remote: list<string> = ["origin"]
	# The name of the configured Git remote(s) from which missing commits will be fetched.
] {
	let remotes = $remote
	let releases_by_commit = read-releases --releases-path $releases_path ...$crates
	enter
	cd $repo_path
	try {
		for entry in $releases_by_commit {
			let get_tag_name = {|release| $"($release.name)-v($release.vers)" }
			try {
				log debug $"checking if ($entry.commit) exists…"
				git show $entry.commit -- | null
				log debug $"commit ($entry.commit) exists, skipping fetch"
			} catch {
				log warning $"commit ($entry.commit) not found, attempting fetch from remote\(s\)…"
				mut found = false
				for remote in $remotes {
					try {
						git fetch $remote $entry.commit
						$found = true
						break
					} catch {
						log warning $'cannot find commit ($entry.commit) from remote ($remote)'
					}
				}
				if not $found {
					log error $"could not find commit ($entry.commit) among specified remote\(s\), skipping tag\(s\) ($entry.releases | each { do $get_tag_name $in })"
					continue
				}
			}
			for release in $entry.releases {
				let tag_name = do $get_tag_name $release
				let ref_exists = not (git tag --list $tag_name | lines | is-empty)
				log debug $"tagging ($tag_name); exists already: ($ref_exists)"

				if not $ref_exists {
					try {
						git tag $tag_name $entry.commit
					} catch {
						log error $"failed to tag commit ($entry.commit) with `($tag_name)`"
					}
				}
			}
		}
	}
	dexit
}
