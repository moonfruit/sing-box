#!/usr/bin/env bash
# 构造一个微型仓库，模拟「reF1nd 基点 + 个人 patch + 上游前进」的形状。
#   moonfruit 分支 = v1.0-reF1nd + 一个 patch 提交
#   v1.1-reF1nd    = 上游前进后的新基点
# mode=clean    上游改动与 patch 不冲突
# mode=conflict 上游改动与 patch 落在同一行
make_fixture() {
  local dir=$1 mode=$2
  git init -q -b main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name  Tester

  printf 'line1\nline2\n' > "$dir/app.go"
  printf 'other\n'         > "$dir/other.go"
  git -C "$dir" add .
  git -C "$dir" commit -qm 'upstream base'
  git -C "$dir" tag v1.0-reF1nd

  git -C "$dir" checkout -q -b moonfruit
  printf 'line1\npatched\n' > "$dir/app.go"
  git -C "$dir" commit -qam 'personal patch'

  git -C "$dir" checkout -q main
  if [[ "$mode" == conflict ]]; then
    printf 'line1\nupstream-changed\n' > "$dir/app.go"
  else
    printf 'other-changed\n' > "$dir/other.go"
  fi
  git -C "$dir" commit -qam 'upstream moves on'
  git -C "$dir" tag v1.1-reF1nd
  git -C "$dir" checkout -q moonfruit
}
