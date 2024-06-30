use std log

const CACHE_DIR = "crunch-cache"

def dl-cached [
	--file: path,
	--url: string,
] {
	if ($file | path exists) {
		log debug $"Cache entry for `($file)` already exists, skipping download"
	} else {
		log debug $"Downloading and caching `($file)` from <($url)>…"
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

export def main [] {
	let crates = [wgpu wgpu-hal wgpu-types wgpu-core d3d12 naga]
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
		| to json o> $'($cache_dir)/releases.json'
}
