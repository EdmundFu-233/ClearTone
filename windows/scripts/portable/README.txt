澄音 ClearTone — Windows 便携版

1. 将 ZIP 完整解压到有写入权限的文件夹，再运行 ClearTone.exe。
2. 设置、登录凭据、播放队列、历史、音频与封面缓存、日志、辅助进程设备 ID，
   均保存在 ClearTone.exe 旁的 data 文件夹。移动或备份应用时请连同 data 一起复制。
3. 双击 Add-to-Start-Menu.bat，在当前用户的开始菜单创建快捷方式，无需管理员权限。
   移动应用目录后，请在新目录重新运行此脚本以更新快捷方式。
4. 双击 Remove-from-Start-Menu.bat，仅移除快捷方式，不删除应用或 data。
5. 更新时请先退出应用，将新版本解压到原目录并覆盖程序文件，保留 data。
   发布 ZIP 不包含用户数据。旧版 AppData 数据不会自动迁入便携目录。

凭据仍使用 Windows DPAPI 加密；复制到另一台电脑或另一 Windows 用户后需要重新登录。
高级调试可用 CLEARTONE_STORAGE_DIR 重定向 data；离线测试由
CLEARTONE_TEST_STORAGE_DIR 优先隔离，正常使用无需设置环境变量。
