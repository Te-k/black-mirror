#!/usr/bin/env bash
set -euo pipefail # put bash into strict mode
umask 055         # change all generated file perms from 755 to 700

# https://github.com/koalaman/shellcheck/wiki/SC2155
DOWNLOADS=$(mktemp -d)
readonly DOWNLOADS
trap 'rm -rf "$DOWNLOADS"' EXIT || exit 1

# params: src_list
get_file_contents() {
    case $1 in
    *.tar.gz)
        # Both Shallalist and Ut-capitole adhere to this format
        # If any archives are added that do not, this line needs to change
        tar -xOzf "$1" --wildcards-match-slash --wildcards '*/domains'
        ;;
    *.zip) zcat "$1" ;;
    *.7z) 7za -y -so e "$1" ;;
    *) cat -s "$1" ;;
    esac
}

# params: engine, rule
parse_file_contents() {
    case $1 in
    cat) cat -s ;;
    mawk) mawk "$2" ;;
    gawk) gawk --sandbox -O -- "$2" ;;
    jq) jq -r "$2" ;;
    miller)
        if [[ $2 =~ ^[0-9]+$ ]]; then
            mlr --mmap --csv --skip-comments -N cut -f "$2"
        else
            mlr --mmap --csv --skip-comments --headerless-csv-output cut -f "$2"
        fi
        ;;
    xmlstarlet)
        # xmlstarlet sel -t -m "/rss/channel/item" -v "substring-before(title,' ')" -n rss.xml
        ;;
    *) ;;
    esac
}

main() {
    local cache_dir
    local src_list
    local list

    for color in 'white' 'black'; do
        cache_dir="${DOWNLOADS}/${color}"

        set +e # temporarily disable strict fail, in case downloads fail
        jq -r --arg color "$color" 'to_entries[] |
        select(.value.color == $color) |
        {key, mirrors: .value.mirrors} |
        .extension = (.mirrors[0] | match(".(tar.gz|zip|7z|json)").captures[0].string // "txt") |
        (.mirrors | join("\t")), " out=\(.key).\(.extension)"' sources/sources.json |
            aria2c --conf-path='./configs/aria2.conf' -d "$cache_dir"
        set -e

        jq -r --arg color "$color" 'to_entries[] |
        select(.value.color == $color) |
         .key as $k | .value.filters[] | "\($k)#\(.engine)#\(.format)#\(.rule)"' sources/sources.json |
            while IFS='#' read -r key engine format rule; do
                src_list=$(find -P -O3 "$cache_dir" -type f -name "$key*")

                if [ -n "$src_list" ]; then
                    get_file_contents "$src_list" |
                        parse_file_contents "$engine" "$rule" |
                        mawk '!seen[$0]++' |
                        if [[ "$format" == 'domain' ]]; then
                            ./scripts/idn_to_punycode.pl
                        else
                            cat -s
                        fi >>"${color}_${format}.txt"
                fi
                # else the download failed and src_list is empty
            done

        for format in 'ipv4' 'ipv6' 'domain'; do
            list="${color}_${format}.txt"

            if test -f "$list"; then
                sort -o "$list" -u -S 90% --parallel=4 -T "$cache_dir" "$list"

                if [[ "$color" == 'black' ]]; then
                    if test -f "white_${format}.txt"; then
                        grep -Fxvf "white_${format}.txt" "$list" | sponge "$list"
                    fi

                    tar -czf "black_${format}.tar.gz" "$list"
                    md5sum "black_${format}.tar.gz" >"black_${format}.md5"
                    sha1sum "black_${format}.tar.gz" >"black_${format}.sha1"
                    sha256sum "black_${format}.tar.gz" >"black_${format}.sha256"
                fi
            fi
        done
    done
}

# https://github.com/koalaman/shellcheck/wiki/SC2218
main
