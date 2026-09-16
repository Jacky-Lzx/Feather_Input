#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "用法：$0 <root-mach-o> <frameworks-directory> <licenses-directory>" >&2
    exit 1
fi

root_binary=$1
frameworks=$2
licenses=$3
if [ ! -f "$root_binary" ] || [ ! -d "$frameworks" ]; then
    echo "Mach-O 根文件或 Frameworks 目录不存在。" >&2
    exit 1
fi

queue=$(mktemp /tmp/feather-dylib-queue.XXXXXX)
seen=$(mktemp /tmp/feather-dylib-seen.XXXXXX)
dependencies=$(mktemp /tmp/feather-dylib-dependencies.XXXXXX)
source_map=$(mktemp /tmp/feather-dylib-sources.XXXXXX)
licensed_prefixes=$(mktemp /tmp/feather-dylib-licenses.XXXXXX)
trap 'rm -f "$queue" "$seen" "$dependencies" "$source_map" "$licensed_prefixes"' EXIT HUP INT TERM
printf '%s\n' "$root_binary" >"$queue"
mkdir -p "$licenses"

while IFS= read -r binary; do
    if grep -Fqx "$binary" "$seen"; then
        continue
    fi
    printf '%s\n' "$binary" >>"$seen"

    otool -L "$binary" | awk '/^[[:space:]]/ { print $1 }' >"$dependencies"
    while IFS= read -r dependency; do
        [ -n "$dependency" ] || continue
        load_path=$dependency
        case "$dependency" in
            /System/* | /usr/lib/* | @loader_path/* | @executable_path/*)
                continue
                ;;
            @rpath/*)
                name=${dependency#@rpath/}
                [ -f "$frameworks/$name" ] && continue
                resolved_dependency=
                previous_ifs=$IFS
                IFS=:
                for search_directory in ${FEATHER_DYLIB_SEARCH_DIRS:-}; do
                    if [ -f "$search_directory/$name" ]; then
                        resolved_dependency="$search_directory/$name"
                        break
                    fi
                done
                IFS=$previous_ifs
                if [ -z "$resolved_dependency" ]; then
                    echo "无法解析动态库加载路径：${dependency}（来自 ${binary}）" >&2
                    echo "请通过 FEATHER_DYLIB_SEARCH_DIRS 提供以冒号分隔的搜索目录。" >&2
                    exit 1
                fi
                dependency=$resolved_dependency
                ;;
            /*) ;;
            *)
                echo "无法识别动态库加载路径：${dependency}（来自 ${binary}）" >&2
                exit 1
                ;;
        esac

        if [ ! -f "$dependency" ]; then
            echo "动态库依赖不存在：${dependency}（来自 ${binary}）" >&2
            exit 1
        fi
        name=$(basename "$dependency")
        canonical_dependency=$(realpath "$dependency")
        package_prefix=${dependency%/lib/*}
        if [ "$package_prefix" = "$dependency" ] || [ ! -d "$package_prefix" ]; then
            echo "无法确定动态库的许可证目录：$dependency" >&2
            exit 1
        fi
        if ! grep -Fqx "$package_prefix" "$licensed_prefixes"; then
            package=$(basename "$package_prefix")
            license_count=0
            for license in \
                "$package_prefix"/LICENSE* \
                "$package_prefix"/COPYING* \
                "$package_prefix"/NOTICE*; do
                [ -f "$license" ] || continue
                cp -L "$license" "$licenses/$package-$(basename "$license")"
                license_count=$((license_count + 1))
            done
            if [ "$license_count" -eq 0 ]; then
                echo "没有找到 $package 的 LICENSE、COPYING 或 NOTICE 文件。" >&2
                exit 1
            fi
            printf '%s\n' "$package_prefix" >>"$licensed_prefixes"
        fi
        bundled="$frameworks/$name"
        if [ ! -e "$bundled" ]; then
            cp -L "$dependency" "$bundled"
            chmod u+w "$bundled"
            codesign --remove-signature "$bundled" 2>/dev/null || true
            install_name_tool -id "@rpath/$name" "$bundled"
            printf '%s\t%s\n' "$name" "$canonical_dependency" >>"$source_map"
            printf '%s\n' "$bundled" >>"$queue"
        else
            recorded_source=$(awk -F '\t' -v name="$name" '$1 == name { print $2; exit }' "$source_map")
            if [ -n "$recorded_source" ] && [ "$recorded_source" != "$canonical_dependency" ]; then
                echo "Frameworks 中出现来自不同位置的同名动态库：$name" >&2
                exit 1
            fi
        fi
        install_name_tool -change "$load_path" "@rpath/$name" "$binary"
    done <"$dependencies"
done <"$queue"
