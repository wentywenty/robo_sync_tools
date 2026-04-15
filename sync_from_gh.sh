#!/bin/bash

# ==========================================
# GitHub -> APT 私有源 高级同步与管理脚本 v3.0
# ==========================================

APT_DIR="/srv/apt"

# 1. 注入代理环境变量
export http_proxy="http://10.43.0.100:7890"
export https_proxy="http://10.43.0.100:7890"
export ALL_PROXY="http://10.43.0.100:7890"

# 检查必备工具
if ! command -v gh &> /dev/null; then
    echo "⚠️ 提示: 未安装 GitHub CLI (gh)。你仍可以使用本地发包功能，但无法从 GitHub 拉取。"
fi

# 目标源列表配置
SUITES=("common" "robopi1" "robopi2" "robopi3" "x86" "取消操作")

# ================= 核心发包函数 =================
# 参数 $1 = 要发布的 .deb 文件路径
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
        reprepro -b "$APT_DIR" remove "$TARGET_SUITE" "$REAL_PKG_NAME"
    fi

    echo ""
    echo "🚀 正在导入 $TARGET_SUITE 源，请准备输入 GPG 密码进行签名..."
    reprepro -b "$APT_DIR" includedeb "$TARGET_SUITE" "$DEB_FILE"

    if [ $? -eq 0 ]; then
        echo "🎉 大功告成！$DEB_FILE 已成功发布到 APT $TARGET_SUITE 源！"
        # 顺手做个小清理，防止旧包占用空间
        reprepro -b "$APT_DIR" deleteunreferenced
    else
        echo "❌ 导入失败，可能是未开启覆盖导致哈希冲突，或 GPG 签名取消。"
    fi
}
# ===============================================

# 进入主循环，操作完不会退出，而是回到主菜单
while true; do
    echo ""
    echo "========================================"
    echo " 🤖 RoboParty 仓库高级分发助手 v3.0"
    echo "========================================"
    
    PS3="👉 请选择主功能序号: "
    select MAIN_OP in "📥 从 GitHub 拉取并发布" "💻 手动发布本地 .deb 包" "🗑️ 移除指定软件包" "🧹 深度体检与批量清理旧包" "🚪 退出脚本"; do
        case $MAIN_OP in
            
            # ==========================================
            # 功能 1：云端拉取发包
            # ==========================================
            "📥 从 GitHub 拉取并发布")
                echo ""
                read -p "请输入 GitHub 仓库名 [直接回车默认 wentywenty/roboto_motors]: " REPO_INPUT
                REPO_NAME=${REPO_INPUT:-"wentywenty/roboto_motors"}

                TMP_DIR=$(mktemp -d)
                # 注意这里不直接 exit 而是跳出当前 case
                cd "$TMP_DIR" || break

                echo ""
                echo "🔍 请选择要拉取包的来源:"
                PS3="👉 请输入来源序号: "
                select SOURCE in "最新 Release (稳定版)" "最新 Actions Artifact (自动构建版)" "取消"; do
                    case $SOURCE in
                        "最新 Release (稳定版)")
                            echo "⏳ 正在从 $REPO_NAME 拉取..."
                            gh release download -R "$REPO_NAME" -p "*.deb"
                            break
                            ;;
                        "最新 Actions Artifact (自动构建版)")
                            echo "⏳ 正在查询最新成功构建..."
                            RUN_ID=$(gh run list -R "$REPO_NAME" --limit 20 --json databaseId,conclusion -q '[.[] | select(.conclusion=="success")][0].databaseId')
                            if [ -n "$RUN_ID" ]; then
                                gh run download "$RUN_ID" -R "$REPO_NAME"
                                find . -mindepth 2 -name "*.deb" -exec mv {} . \;
                            else
                                echo "❌ 找不到成功记录！"
                            fi
                            break
                            ;;
                        "取消") break 2 ;; # 直接跳出到主菜单
                        *) echo "❌ 无效序号" ;;
                    esac
                done

                shopt -s nullglob
                DEB_FILES=(*.deb)
                if [ ${#DEB_FILES[@]} -eq 0 ]; then
                    echo "❌ 拉取失败或没有找到 .deb 文件。"
                else
                    echo ""
                    echo "📦 找到以下安装包，请选择要发布的包:"
                    PS3="👉 请输入包序号: "
                    select SELECTED_DEB in "${DEB_FILES[@]}"; do
                        if [ -n "$SELECTED_DEB" ]; then
                            # 调用核心发包函数
                            publish_package "$SELECTED_DEB"
                            break
                        fi
                    done
                fi
                
                # 清理临时目录并回到主菜单
                cd - > /dev/null
                rm -rf "$TMP_DIR"
                break
                ;;

            # ==========================================
            # 功能 2：本地指定文件发包 (带 Tab 补全)
            # ==========================================
            "💻 手动发布本地 .deb 包")
                echo ""
                echo "💡 提示: 路径支持按 Tab 键自动补全！"
                read -e -p "📂 请输入本地 .deb 文件的路径: " LOCAL_DEB_FILE
                
                # 去掉路径两边可能带入的引号（如果有）
                LOCAL_DEB_FILE=$(eval echo "$LOCAL_DEB_FILE")

                if [ ! -f "$LOCAL_DEB_FILE" ]; then
                    echo "❌ 找不到文件: $LOCAL_DEB_FILE ，请检查路径是否拼写正确。"
                elif [[ "$LOCAL_DEB_FILE" != *.deb ]]; then
                    echo "❌ 警告: 这看起来不像是一个 .deb 文件！"
                else
                    # 路径正确，直接调用核心发包函数
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
                read -p "📦 请输入要删除的准确包名 (例如 roboto-bms, 不是.deb文件名): " DEL_PKG
                if [ -n "$DEL_PKG" ]; then
                    echo "⚠️ 正在从 $DEL_SUITE 移除 $DEL_PKG ..."
                    reprepro -b "$APT_DIR" remove "$DEL_SUITE" "$DEL_PKG"
                    # 删除完顺便清垃圾
                    reprepro -b "$APT_DIR" deleteunreferenced
                    echo "✅ 删除完成！"
                fi
                break
                ;;

            # ==========================================
            # 功能 4：系统体检与垃圾回收 (批量清理旧包)
            # ==========================================
            "🧹 深度体检与批量清理旧包")
                echo ""
                echo "🛠️ 正在刷新所有源的索引树 (exporting)..."
                reprepro -b "$APT_DIR" export
                
                echo "🧹 正在扫描并彻底删除所有已经被新版本淘汰的物理旧包 (deleteunreferenced)..."
                reprepro -b "$APT_DIR" deleteunreferenced
                
                echo "🔎 正在检查 APT 仓库数据库完整性 (check)..."
                reprepro -b "$APT_DIR" check
                reprepro -b "$APT_DIR" checkpool
                
                echo "✅ 体检与清理完毕！你的源现在极其健康且不占多余空间。"
                break
                ;;

            # ==========================================
            # 功能 5：退出
            # ==========================================
            "🚪 退出脚本")
                echo "🚪 拜拜！"
                exit 0
                ;;

            *) echo "❌ 无效的序号，请重新输入。" ;;
        esac
    done
done