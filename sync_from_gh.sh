#!/bin/bash

# ==========================================
# GitHub (Release/Actions) -> APT 私有源 同步脚本
# ==========================================

APT_DIR="/srv/apt"

# 1. 注入代理环境变量 (解决你拉取和认证超时的问题)
export http_proxy="http://10.43.0.100:7890"
export https_proxy="http://10.43.0.100:7890"
export ALL_PROXY="http://10.43.0.100:7890"

# 2. 检查必备工具
if ! command -v gh &> /dev/null; then
    echo "❌ 错误: 未安装 GitHub CLI (gh)。请先执行 'sudo apt install gh'"
    exit 1
fi

echo "========================================"
echo " 🤖 RoboParty 仓库高级分发助手"
echo "========================================"

# 3. 仓库输入与环境清理
# 这里我加了一个默认值，直接按回车就能用默认仓库，省得每次敲
read -p "请输入 GitHub 仓库名 [直接回车默认 wentywenty/roboto_motors]: " REPO_INPUT
REPO_NAME=${REPO_INPUT:-"wentywenty/roboto_motors"}

TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR; echo '🧹 临时清理完毕。'" EXIT
cd "$TMP_DIR" || exit

# 4. 选择拉取来源
echo ""
echo "🔍 请选择要拉取包的来源:"
PS3="👉 请输入来源序号: "
select SOURCE in "最新 Release (稳定版)" "最新 Actions Artifact (自动构建版)" "退出"; do
    case $SOURCE in
        "最新 Release (稳定版)")
            echo "⏳ 正在从 $REPO_NAME 拉取最新 Release..."
            gh release download -R "$REPO_NAME" -p "*.deb"
            break
            ;;
        "最新 Actions Artifact (自动构建版)")
            echo "⏳ 正在查询 $REPO_NAME 的最新成功构建(Actions)..."
            # 兼容老版本 gh：拉取最近 20 条，用 jq 语法筛选出 conclusion 为 success 的第一条
            RUN_ID=$(gh run list -R "$REPO_NAME" --limit 20 --json databaseId,conclusion -q '[.[] | select(.conclusion=="success")][0].databaseId')
            if [ -z "$RUN_ID" ]; then
                echo "❌ 找不到最近的成功构建记录！"
                exit 1
            fi
            echo "📥 正在下载 Run ID: $RUN_ID 的产物..."
            # gh 下载 artifacts 会自动解压成子文件夹
            gh run download "$RUN_ID" -R "$REPO_NAME"
            
            # 把所有子目录里的 .deb 文件移动到当前临时目录根下，方便识别
            find . -mindepth 2 -name "*.deb" -exec mv {} . \;
            break
            ;;
        "退出")
            echo "🚪 已退出。"
            exit 0
            ;;
        *)
            echo "❌ 无效的序号，请重新输入。"
            ;;
    esac
done

# 5. 检查是否找到包
shopt -s nullglob
DEB_FILES=(*.deb)
if [ ${#DEB_FILES[@]} -eq 0 ]; then
    echo "❌ 拉取成功，但没有找到任何 .deb 文件。"
    exit 1
fi

# 6. [高级功能] 如果包来自 Actions，询问是否要同步发布到 Release
if [ "$SOURCE" == "最新 Actions Artifact (自动构建版)" ]; then
    echo ""
    read -p "🚀 是否将这些 Actions 产物正式发布为 GitHub Release? (y/N): " PUSH_RELEASE
    if [[ "$PUSH_RELEASE" == "y" || "$PUSH_RELEASE" == "Y" ]]; then
        read -p "🏷️ 请输入新的 Release 版本号 (例如 v1.1.0): " REL_TAG
        if [ -n "$REL_TAG" ]; then
            echo "⬆️ 正在创建 Release $REL_TAG 并上传包..."
            # 使用 gh release create 将当前目录下的所有 deb 上传
            gh release create "$REL_TAG" *.deb -R "$REPO_NAME" --title "Release $REL_TAG" --notes "Automated release from Actions build $RUN_ID"
            if [ $? -eq 0 ]; then
                echo "✅ GitHub Release $REL_TAG 发布成功！"
            else
                echo "❌ GitHub Release 发布失败，可能是 tag 已存在或权限不足。"
            fi
        fi
    fi
fi

# 7. 交互式选择：要导入 APT 的包
echo ""
echo "📦 找到以下安装包，请选择要导入内网 APT 源的包:"
PS3="👉 请输入包序号: "
select SELECTED_DEB in "${DEB_FILES[@]}"; do
    if [ -n "$SELECTED_DEB" ]; then
        echo "✅ 你选择了: $SELECTED_DEB"
        break
    else
        echo "❌ 无效的序号，请重新输入。"
    fi
done

# 8. 交互式选择：目标板卡源 (Suite)
echo ""
echo "🎯 请选择要发布到的目标源 (Suite):"
SUITES=("common" "robopi1" "robopi2" "robopi3" "取消发布 APT")
PS3="👉 请输入源序号: "
select TARGET_SUITE in "${SUITES[@]}"; do
    if [ "$TARGET_SUITE" == "取消发布 APT" ]; then
        echo "🚪 已跳过 APT 源更新。"
        exit 0
    elif [ -n "$TARGET_SUITE" ]; then
        echo "✅ 目标源设为: $TARGET_SUITE"
        break
    else
        echo "❌ 无效的序号，请重新输入。"
    fi
done

# 9. 执行 reprepro 导入
echo ""
echo "🚀 正在导入 $TARGET_SUITE 源，请准备输入 GPG 密码进行签名..."
reprepro -b "$APT_DIR" includedeb "$TARGET_SUITE" "$SELECTED_DEB"

if [ $? -eq 0 ]; then
    echo "🎉 大功告成！$SELECTED_DEB 已成功发布到 APT $TARGET_SUITE 源！"
else
    echo "❌ 导入失败，请检查 GPG 状态或包的 control 文件配置。"
fi
