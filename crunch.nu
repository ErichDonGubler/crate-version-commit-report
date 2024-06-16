const cache_dir = "crunch-cache"

export def "crunch dl-versions" [
	...crates: string,
] {
	# TODO: cache
	$crates | each {|crate|
		let file = $"($cache_dir)/versions/($crate).json"
		mkdir ($file | path dirname)
		curl -o $file -L $'https://index.crates.io/($crate | str substring 0..1)/($crate | str substring 2..3)/($crate)'
		$file
	}
}

export def "crunch list-versions" [
	...files: path,
] {
	$files | reduce --fold [] {|file, acc|
		$acc | append (open --raw $file | from json --objects)
	}
}

export def "crunch dl-tarball" [
	name: string,
	version: string,
] {
	# TODO: cache
	let url = $'https://crates.io/api/v1/crates/($name)/($version)/download'
	let file = $'($cache_dir)/packages/($name)-($version).crate'
	mkdir ($file | path dirname)
	curl -o $file -L $url
	$file
}

export def main [] {
	let crates = [wgpu wgpu-hal wgpu-types wgpu-core d3d12 naga]
	let version_index_files = crunch dl-versions ...$crates
	let crate_version_table = crunch list-versions ...$version_index_files | select name vers
	let crate_tarballs = $crate_version_table | insert tarball {|crate|
		crunch dl-tarball $crate.name $crate.vers
	}
	let crate_version_commits = $crate_tarballs | insert commit {|crate|
		let extracted_dir = $'($cache_dir)/packages-extracted'
		ouch decompress --format tar.gz $crate.tarball --dir $extracted_dir
		let dir = $'($extracted_dir)/($crate.name)-($crate.vers)'
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
