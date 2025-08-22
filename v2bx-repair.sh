# —— 总是重启 nezha-agent（无论成功/失败/在哪退出）——
NEZHA_SERVICE="nezha-agent"

restart_nezha() {
  echo "[INFO] 重启 ${NEZHA_SERVICE}..."

  # 如果 systemctl 可用
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
    systemctl reset-failed "${NEZHA_SERVICE}.service" || true

    # 尝试重启
    local errf; errf="$(mktemp)"
    if systemctl restart --no-ask-password "${NEZHA_SERVICE}.service" 2>"$errf"; then
      systemctl is-active --quiet "${NEZHA_SERVICE}.service" && { echo "[OK] nezha-agent 已重启"; rm -f "$errf"; return 0; }
    fi

    # 检查错误信息
    local err_msg; err_msg="$(cat "$errf" || true)"; rm -f "$errf"
    if echo "$err_msg" | grep -qi "Transport endpoint is not connected"; then
      echo "[WARN] systemd 通信断开，执行 daemon-reexec 后重试..."
      systemctl daemon-reexec || true
      sleep 1
      if systemctl restart --no-ask-password "${NEZHA_SERVICE}.service"; then
        systemctl is-active --quiet "${NEZHA_SERVICE}.service" && { echo "[OK] nezha-agent 已重启（reexec 后）"; return 0; }
      fi
    fi

    # 第二道保险：用 systemd-run 开 scope
    if command -v systemd-run >/dev/null 2>&1; then
      echo "[WARN] 使用 systemd-run 在独立 scope 中重启..."
      systemd-run --quiet --collect --unit=nezha-restart-$$ \
        /bin/sh -c "systemctl restart --no-ask-password ${NEZHA_SERVICE}.service"
      sleep 1
      systemctl is-active --quiet "${NEZHA_SERVICE}.service" && { echo "[OK] nezha-agent 已重启（scope）"; return 0; }
    fi
  fi

  # 最后兜底：直接按 ExecStart 启动
  echo "[WARN] 进入兜底流程，尝试直接拉起 nezha-agent..."
  local exec_line cmd
  exec_line="$(systemctl show -p ExecStart --value "${NEZHA_SERVICE}.service" 2>/dev/null || true)"
  cmd="$(printf '%s' "$exec_line" | sed 's/^[^=]*=//; s/;.*$//; s/^-[[:space:]]*//')"
  if [ -n "$cmd" ]; then
    pkill -f nezha-agent || true
    nohup sh -c "$cmd" >/var/log/nezha-agent.fallback.log 2>&1 &
    sleep 1
    pgrep -f nezha-agent >/dev/null 2>&1 && { echo "[OK] 兜底直启成功"; return 0; }
  fi

  echo "[ERROR] nezha-agent 重启失败，请检查 systemctl status/journalctl 日志"
  return 1
}
