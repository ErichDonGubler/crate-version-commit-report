use std log

const CACHE_DIR = path self "./crunch-cache/"
const RELEASES_JSON_PATH = [$CACHE_DIR "releases.json"] | path join

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
		log debug $"downloading version index for `($crate)`"
		(
			dl-cached
				--file $"($CACHE_DIR)/versions/($crate).json"
				--url $'https://index.crates.io/($crate | str substring 0..1)/($crate | str substring 2..3)/($crate)'
		)
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
	if (which ouch | is-empty) {
		print --stderr "fatal: `ouch` not found, bailing"
	}

	let version_index_files = dl-versions ...$crates
	let crate_version_table = list-versions ...$version_index_files | select name vers
	log info $"caching ($crate_version_table | get name | uniq | length) crates with ($crate_version_table | length) versions…"
	let crate_tarballs = $crate_version_table | insert tarball {|crate|
		log debug $"downloading tarballs for versions of `($crate.name)`"
		dl-tarball $crate.name $crate.vers
	}
	let crate_version_commits = $crate_tarballs | insert commit {|crate|
		let extracted_dir = $'($CACHE_DIR)/packages-extracted'
		let dir = $'($extracted_dir)/($crate.name)-($crate.vers)'

		if ($dir | path exists) {
			log debug $"Cache entry exists at `($dir)`, skipping archive extraction…"
		} else {
			log debug $"Decompressing `($crate.tarball)` into `($dir)`…"
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

	--remotes: list<string> = ["origin"]
	# The name of the configured Git remote(s) from which missing commits will be fetched.
] {
	let releases_by_commit = read-releases --releases-path $releases_path ...$crates
	cd $repo_path
	try {
		for entry in $releases_by_commit {
			let get_tag_name = {|release| $"($release.name)-v($release.vers)" }
			try {
				log debug $"checking if ($entry.commit) exists…"
				git cat-file commit $entry.commit
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
				let tag_missing = git tag --list $tag_name | lines | is-empty
				log debug $"tagging ($tag_name); exists already: (not $tag_missing)"

				if $tag_missing {
					try {
						git tag $tag_name $entry.commit
					} catch {
						log error $"failed to tag commit ($entry.commit) with `($tag_name)`"
					}
				}
			}
		}
	}
}

export def "wgpu" [
	--repo-path: directory = "scratch/wgpu"
] {
	let crates = wgpu crate-members-to-publish --repo-path $repo_path | get name
	let remotes = [
		...("https://github.com/{cwfitzgerald,gfx-rs,kvark}/wgpu{,-rs}" | str expand)
		...("https://github.com/{cwfitzgerald,gfx-rs,kvark}/naga" | str expand)
	]

	populate-cache ...$crates
	tag ...$crates --repo-path $repo_path --remotes $remotes
}

export def "wgpu crate-members-to-publish" [
	--repo-path: directory = "scratch/wgpu"
] {
	let cargo_metadata = (
		cargo metadata --format-version 1
			--manifest-path ($repo_path | path join 'Cargo.toml')
	) | from json

	let workspace_members = $cargo_metadata
		| get workspace_members
		| parse 'path+file://{abs_path}#{version_fragment}'
		| update version_fragment {|entry|
			parse --regex '(?:(?P<name>[a-zA-Z0-9-]+)@)?(?P<version>\d+\.\d+\.\d+)'
				| first
				| update name {
					if ($in | is-empty) {
						($entry.abs_path | path basename)
					} else {
						$in
					}
				}
		}
		| flatten version_fragment
		| where name !~ '^deno'

	let publishable = $cargo_metadata
		| get packages
		| where name in ($workspace_members | get name) and publish != []
		| get name

	$workspace_members | where name in $publishable
}
