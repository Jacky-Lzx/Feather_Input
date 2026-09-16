#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "用法：$0 <app-bundle>" >&2
    exit 1
fi

app=$1
frameworks="$app/Contents/Frameworks"
if [ ! -d "$app/Contents/MacOS" ] || [ ! -d "$frameworks" ]; then
    echo "应用 bundle 结构无效：$app" >&2
    exit 1
fi

failures=$(mktemp /tmp/feather-dylib-check.XXXXXX)
trap 'rm -f "$failures"' EXIT HUP INT TERM
find "$app/Contents/MacOS" "$frameworks" -type f -print | while IFS= read -r binary; do
    file "$binary" | grep -q 'Mach-O' || continue
    otool -L "$binary" | awk '/^[[:space:]]/ { print $1 }' | while IFS= read -r dependency; do
        case "$dependency" in
            /System/* | /usr/lib/* | @loader_path/* | @executable_path/*) ;;
            @rpath/*)
                name=${dependency#@rpath/}
                if [ ! -f "$frameworks/$name" ]; then
                    echo "缺少 @rpath 依赖：${dependency}（来自 ${binary}）" >&2
                    printf '.\n' >>"$failures"
                fi
                ;;
            *)
                echo "存在非便携动态库路径：${dependency}（来自 ${binary}）" >&2
                printf '.\n' >>"$failures"
                ;;
        esac
    done
done

if [ -s "$failures" ]; then
    exit 1
fi
