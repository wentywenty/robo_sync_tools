#!/bin/bash

# ==========================================
# GitHub -> APT 私有源 高级同步与管理脚本 v3.2
# ==========================================

APT_DIR="/srv/apt"

# 检查必备工具
if ! command -v gh &> /dev/null; then
    echo "⚠️ 提示: 未安装 GitHub CLI (gh)。你仍可以使用本地发包功能，但无法从 GitHub 拉取。"
fi
if ! command -v unzip &> /dev/null; then
    echo "⚠️ 提示: 未安装 unzip 工具。如果有 .zip 压缩包产物将无法自动解压，建议执行 sudo apt install unzip"
fi

# 目标源列表配置
SUITES=("common" "robopi1" "robopi2" "robopi3" "x86" "取消操作")

# ================= 核心发包函数 (单个发包) =================
publish_package() {
    local DEB_FILE="$1"

    echo ""
    echo "🎯 请选择要发布到的目标源 (Suite):"
    PS3="👉 请输入源序号: "
    select TARGET_SUITE in "${SUITES[@]}"; do
        if [ "$TARGET_SUITE" == "取消操作" ]; then
            echo "🚪 已跳过发布。"
            return
        elif [ -n "$TARGET_SUITE" ]; then
            break
        else
            echo "❌ 无效的序号。"
        fi
    done

    echo ""
    read -p "⚠️ 是否开启强制覆盖？(版本号不变时，先删源里的旧包再发新包) [y/N]: " FORCE_OVERRIDE
    if [[ "$FORCE_OVERRIDE" == "y" || "$FORCE_OVERRIDE" == "Y" ]]; then
        REAL_PKG_NAME=$(dpkg-deb -f "$DEB_FILE" Package)
        echo "🗑️ 正在从 $TARGET_SUITE 源中移除旧版 $REAL_PKG_NAME ..."
        reprepro -b "$APT_DIR" remove "$TARGET_SUITE" "$REAL_PKG_NAME" >/dev/null 2>&1
    fi

    echo ""
    echo "🚀 正在导入 $TARGET_SUITE 源，请准备输入 GPG 密码进行签名..."
    reprepro -b "$APT_DIR" includedeb "$TARGET_SUITE" "$DEB_FILE"

    if [ $? -eq 0 ]; then
        echo "🎉 大功告成！$DEB_FILE 已成功发布到 APT $TARGET_SUITE 源！"
        reprepro -b "$APT_DIR" deleteunreferenced
    else
        echo "❌ 导入失败，可能是未开启覆盖导致哈希冲突，或 GPG 签名取消。"
    fi
}
# ===============================================

# 进入主循环
while true; do
    echo ""
    echo "========================================"
    echo " 🤖 RoboParty 仓库高级分发助手 v3.2"
    echo "========================================"

    PS3="👉 请选择主功能序号: "
    select MAIN_OP in "📥 从 GitHub 拉取并发布 (支持Zip自动解压)" "📤 从 Artifact 创建 GitHub Release" "💻 手动发布本地 .deb 包" "🗑️ 移除指定软件包" "🧹 深度体检与批量清理旧包" "🚪 退出脚本"; do
        case $MAIN_OP in

            # ==========================================
            # 功能 1：云端拉取发包
            # ==========================================
            "📥 从 GitHub 拉取并发布 (支持Zip自动解压)")
                echo ""
                read -p "请输入 GitHub 仓库名 [直接回车默认 wentywenty/roboto_motors]: " REPO_INPUT
                REPO_NAME=${REPO_INPUT:-"wentywenty/roboto_motors"}

                TMP_DIR=$(mktemp -d)
                cd "$TMP_DIR" || break

                echo ""
                echo "🔍 请选择要拉取包的来源:"
                PS3="👉 请输入来源序号: "
                select SOURCE in "最新 Release (稳定版)" "最新 Actions Artifact (自动构建版)" "取消"; do
                    case $SOURCE in
                        "最新 Release (稳定版)")
                            echo "⏳ 正在从 $REPO_NAME 拉取..."
                            # 同时拉取 deb 和 zip 格式
                            if ! gh release download -R "$REPO_NAME" -p "*.deb" -p "*.zip" 2>&1; then
                                echo "⚠️ 未找到 .deb 或 .zip 资源，尝试拉取所有文件..."
                                if ! gh release download -R "$REPO_NAME" -p "*"; then
                                    echo "❌ 该 Release 没有任何可下载的资源。"
                                fi
                            fi
                            break
                            ;;
                        "最新 Actions Artifact (自动构建版)")
                            echo "⏳ 正在查询最新成功构建..."
                            # 尝试自动获取最新的 success 记录
                            AUTO_RUN_ID=$(gh run list -R "$REPO_NAME" --limit 20 --json databaseId,conclusion -q '[.[] | select(.conclusion=="success")][0].databaseId')
                            
                            if [ -n "$AUTO_RUN_ID" ] && [ "$AUTO_RUN_ID" != "null" ]; then
                                echo "✅ 自动找到最新完美成功记录: $AUTO_RUN_ID"
                            else
                                echo "⚠️ 前20条里没找到全是绿勾(success)的记录，或者包含警告。"
                            fi

                            echo ""
                            echo "💡 你可以直接粘贴指定的 Run ID (比如你刚发的 24829934595)"
                            read -p "👉 请输入 Run ID [直接回车默认使用 $AUTO_RUN_ID]: " INPUT_RUN_ID
                            
                            # 如果用户输入了就用用户的，没输入就用自动获取的
                            FINAL_RUN_ID=${INPUT_RUN_ID:-$AUTO_RUN_ID}

                            if [ -n "$FINAL_RUN_ID" ] && [ "$FINAL_RUN_ID" != "null" ]; then
                                echo "📥 正在疯狂下载 Run ID: $FINAL_RUN_ID 的产物..."
                                gh run download "$FINAL_RUN_ID" -R "$REPO_NAME"
                            else
                                echo "❌ 下载取消：没有有效的 Run ID！"
                            fi
                            break
                            ;;
                        "取消") break 2 ;;
                        *) echo "❌ 无效序号" ;;
                    esac
                done

                # --- 核心新增：全自动 Zip 提取引擎 ---
                if command -v unzip &> /dev/null; then
                    while IFS= read -r zip_file; do
                        echo "📦 发现压缩包 $zip_file，正在自动解压..."
                        unzip -q -o "$zip_file" -d "$(dirname "$zip_file")"
                    done < <(find . -type f -name "*.zip")
                fi
                # 将所有子文件夹里隐藏的 deb 包全部提拔到当前目录
                find . -mindepth 2 -type f -name "*.deb" -exec mv {} . \;
                # ------------------------------------

                shopt -s nullglob
                DEB_FILES=(*.deb)
                if [ ${#DEB_FILES[@]} -eq 0 ]; then
                    echo "❌ 拉取失败或解压后没有找到任何 .deb 文件。"
                else
                    echo ""
                    echo "📦 找到以下安装包:"
                    
                    # --- 核心新增：如果大于1个包，增加批量发布选项 ---
                    if [ ${#DEB_FILES[@]} -gt 1 ]; then
                        OPTIONS=("${DEB_FILES[@]}" "🌟 批量发布以上所有包" "取消")
                    else
                        OPTIONS=("${DEB_FILES[@]}" "取消")
                    fi

                    PS3="👉 请输入包序号: "
                    select SELECTED_OP in "${OPTIONS[@]}"; do
                        if [ "$SELECTED_OP" == "取消" ]; then
                            echo "🚪 已取消操作。"
                            break
                        elif [ "$SELECTED_OP" == "🌟 批量发布以上所有包" ]; then
                            echo ""
                            echo "🎯 请选择要【批量发布】到的目标源 (Suite):"
                            PS3="👉 请输入源序号: "
                            select TARGET_SUITE in "${SUITES[@]}"; do
                                if [ "$TARGET_SUITE" == "取消操作" ]; then break 2; fi
                                if [ -n "$TARGET_SUITE" ]; then break; fi
                            done

                            echo ""
                            read -p "⚠️ 是否开启强制覆盖？(批量替换源内同名旧包) [y/N]: " FORCE_OVERRIDE

                            for deb in "${DEB_FILES[@]}"; do
                                echo "----------------------------------------"
                                echo "🚀 正在处理: $deb"
                                if [[ "$FORCE_OVERRIDE" == "y" || "$FORCE_OVERRIDE" == "Y" ]]; then
                                    REAL_PKG_NAME=$(dpkg-deb -f "$deb" Package)
                                    reprepro -b "$APT_DIR" remove "$TARGET_SUITE" "$REAL_PKG_NAME" >/dev/null 2>&1
                                fi
                                reprepro -b "$APT_DIR" includedeb "$TARGET_SUITE" "$deb"
                            done
                            
                            reprepro -b "$APT_DIR" deleteunreferenced
                            echo "🎉 批量发布大功告成！所有包已就绪。"
                            break
                        elif [ -n "$SELECTED_OP" ]; then
                            publish_package "$SELECTED_OP"
                            break
                        fi
                    done
                fi

                cd - > /dev/null
                rm -rf "$TMP_DIR"
                break
                ;;

            # ==========================================
            # 功能 2：从 Artifact 创建 GitHub Release
            # ==========================================
            "📤 从 Artifact 创建 GitHub Release")
                echo ""
                read -p "请输入 GitHub 仓库名 [直接回车默认 wentywenty/roboto_motors]: " REPO_INPUT
                REPO_NAME=${REPO_INPUT:-"wentywenty/roboto_motors"}

                echo ""
                read -p "🏷️ 请输入发布版本号 (例如 v1.2.3): " RELEASE_TAG
                if [ -z "$RELEASE_TAG" ]; then
                    echo "❌ 版本号不能为空，已取消操作。"
                    break
                fi

                # 检查 tag 是否已存在
                RELEASE_EXISTS=false
                if gh release view "$RELEASE_TAG" -R "$REPO_NAME" >/dev/null 2>&1; then
                    echo "⚠️ Release $RELEASE_TAG 已存在！"
                    read -p "🗑️ 是否删除旧 Release 并重新发布？ [y/N]: " DELETE_OLD
                    if [[ "$DELETE_OLD" != "y" && "$DELETE_OLD" != "Y" ]]; then
                        echo "🚪 已取消操作。"
                        break
                    fi
                    echo "🗑️ 正在删除旧 Release $RELEASE_TAG ..."
                    gh release delete "$RELEASE_TAG" -R "$REPO_NAME" --yes
                    gh api -X DELETE "repos/$REPO_NAME/git/refs/tags/$RELEASE_TAG" 2>/dev/null || true
                    if [ $? -ne 0 ]; then
                        echo "❌ 删除旧 Release 失败，请手动处理。"
                        break
                    fi
                    echo "✅ 旧 Release 已删除。"
                    RELEASE_EXISTS=true
                fi

                echo ""
                read -p "📝 请输入 Release 标题 [直接回车默认使用版本号 $RELEASE_TAG]: " RELEASE_TITLE
                RELEASE_TITLE=${RELEASE_TITLE:-$RELEASE_TAG}

                echo ""
                read -p "📋 请输入 Release 描述 (可选，直接回车跳过): " RELEASE_NOTES

                TMP_DIR=$(mktemp -d)
                cd "$TMP_DIR" || break

                echo ""
                echo "🔍 请选择要拉取 Artifact 包的来源:"
                PS3="👉 请输入来源序号: "
                select SOURCE in "最新 Actions Artifact (自动构建版)" "指定 Run ID" "取消"; do
                    case $SOURCE in
                        "最新 Actions Artifact (自动构建版)")
                            echo "⏳ 正在查询最新成功构建..."
                            AUTO_RUN_ID=$(gh run list -R "$REPO_NAME" --limit 20 --json databaseId,conclusion -q '[.[] | select(.conclusion=="success")][0].databaseId')

                            if [ -n "$AUTO_RUN_ID" ] && [ "$AUTO_RUN_ID" != "null" ]; then
                                echo "✅ 自动找到最新成功记录: $AUTO_RUN_ID"
                            else
                                echo "⚠️ 前20条里没找到 success 的记录。"
                            fi

                            echo ""
                            read -p "👉 请输入 Run ID [直接回车默认使用 $AUTO_RUN_ID]: " INPUT_RUN_ID
                            FINAL_RUN_ID=${INPUT_RUN_ID:-$AUTO_RUN_ID}
                            break
                            ;;
                        "指定 Run ID")
                            read -p "👉 请输入 Run ID: " INPUT_RUN_ID
                            FINAL_RUN_ID=$INPUT_RUN_ID
                            break
                            ;;
                        "取消") break 3 ;;
                        *) echo "❌ 无效序号" ;;
                    esac
                done

                if [ -z "$FINAL_RUN_ID" ] || [ "$FINAL_RUN_ID" == "null" ]; then
                    echo "❌ 没有有效的 Run ID，操作取消。"
                    cd - > /dev/null
                    rm -rf "$TMP_DIR"
                    break
                fi

                echo "📥 正在下载 Run ID: $FINAL_RUN_ID 的产物 (请稍候)..."
                DOWNLOAD_OUTPUT=$(gh run download "$FINAL_RUN_ID" -R "$REPO_NAME" -D "$TMP_DIR/downloaded_artifacts" 2>&1)
                DOWNLOAD_RC=$?
                echo "📥 下载命令执行完毕。"

                if [ $DOWNLOAD_RC -ne 0 ]; then
                    echo "❌ 下载 Artifact 失败:"
                    echo "$DOWNLOAD_OUTPUT"
                    cd - > /dev/null
                    rm -rf "$TMP_DIR"
                    break
                fi

                # 收集所有需要上传的文件 (.deb, .zip)
                UPLOAD_FILES=()
                while IFS= read -r -d '' f; do
                    UPLOAD_FILES+=("$f")
                done < <(find "$TMP_DIR/downloaded_artifacts" -type f \( -name "*.deb" -o -name "*.zip" \) -print0)

                if [ ${#UPLOAD_FILES[@]} -eq 0 ]; then
                    echo "⚠️ Artifact 中没有找到 .deb 或 .zip 文件，将上传所有文件。"
                    while IFS= read -r -d '' f; do
                        UPLOAD_FILES+=("$f")
                    done < <(find "$TMP_DIR/downloaded_artifacts" -type f -print0)
                fi

                if [ ${#UPLOAD_FILES[@]} -eq 0 ]; then
                    echo "❌ Artifact 中没有任何文件，操作取消。"
                    cd - > /dev/null
                    rm -rf "$TMP_DIR"
                    break
                fi

                echo ""
                echo "📦 将上传以下文件到 Release $RELEASE_TAG:"
                for f in "${UPLOAD_FILES[@]}"; do
                    echo "   - $(basename "$f")"
                done

                echo ""
                read -p "🚀 确认创建 Release 并上传以上文件？ [Y/n]: " CONFIRM_RELEASE
                if [[ "$CONFIRM_RELEASE" == "n" || "$CONFIRM_RELEASE" == "N" ]]; then
                    echo "🚪 已取消操作。"
                    cd - > /dev/null
                    rm -rf "$TMP_DIR"
                    break
                fi

                echo ""
                echo "🏷️ 正在创建 Release $RELEASE_TAG ..."

                # 构建 gh release create 命令
                RELEASE_CMD=(gh release create "$RELEASE_TAG" -R "$REPO_NAME" -t "$RELEASE_TITLE")
                if [ -n "$RELEASE_NOTES" ]; then
                    RELEASE_CMD+=(-n "$RELEASE_NOTES")
                fi

                # 添加所有上传文件
                for f in "${UPLOAD_FILES[@]}"; do
                    RELEASE_CMD+=("$f")
                done

                # 执行发布
                "${RELEASE_CMD[@]}"

                if [ $? -eq 0 ]; then
                    echo ""
                    echo "🎉 Release $RELEASE_TAG 创建成功！"
                    echo "🔗 查看地址: https://github.com/$REPO_NAME/releases/tag/$RELEASE_TAG"
                else
                    echo ""
                    echo "❌ Release 创建失败，请检查错误信息。"
                fi

                cd - > /dev/null
                rm -rf "$TMP_DIR"
                break
                ;;

            # ==========================================
            # 功能 3：本地指定文件发包
            # ==========================================
            "💻 手动发布本地 .deb 包")
                echo ""
                echo "💡 提示: 路径支持按 Tab 键自动补全！"
                read -e -p "📂 请输入本地 .deb 文件的路径: " LOCAL_DEB_FILE

                LOCAL_DEB_FILE=$(eval echo "$LOCAL_DEB_FILE")

                if [ ! -f "$LOCAL_DEB_FILE" ]; then
                    echo "❌ 找不到文件: $LOCAL_DEB_FILE"
                elif [[ "$LOCAL_DEB_FILE" != *.deb ]]; then
                    echo "❌ 警告: 这不是一个 .deb 文件！"
                else
                    publish_package "$LOCAL_DEB_FILE"
                fi
                break
                ;;

            # ==========================================
            # 功能 3：手动删除包
            # ==========================================
            "🗑️ 移除指定软件包")
                echo ""
                echo "🎯 请选择要操作的目标源 (Suite):"
                PS3="👉 请输入源序号: "
                select DEL_SUITE in "${SUITES[@]}"; do
                    if [ "$DEL_SUITE" == "取消操作" ]; then break 2; fi
                    if [ -n "$DEL_SUITE" ]; then break; fi
                done

                echo ""
                read -p "📦 请输入要删除的准确包名 (例如 roboto-bms): " DEL_PKG
                if [ -n "$DEL_PKG" ]; then
                    echo "⚠️ 正在从 $DEL_SUITE 移除 $DEL_PKG ..."
                    reprepro -b "$APT_DIR" remove "$DEL_SUITE" "$DEL_PKG"
                    reprepro -b "$APT_DIR" deleteunreferenced
                    echo "✅ 删除完成！"
                fi
                break
                ;;

            # ==========================================
            # 功能 4：系统清理
            # ==========================================
            "🧹 深度体检与批量清理旧包")
                echo ""
                echo "🛠️ 正在刷新索引..."
                reprepro -b "$APT_DIR" export
                echo "🧹 正在删除无用旧包..."
                reprepro -b "$APT_DIR" deleteunreferenced
                echo "🔎 正在检查数据库完整性..."
                reprepro -b "$APT_DIR" check
                echo "✅ 体检与清理完毕！源空间已优化。"
                break
                ;;

            "🚪 退出脚本")
                echo "🚪 拜拜！"
                exit 0
                ;;

            *) echo "❌ 无效的序号，请重新输入。" ;;
        esac
    done
done