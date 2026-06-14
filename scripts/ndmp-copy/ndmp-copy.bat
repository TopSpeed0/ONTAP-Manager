@echo off
REM NDMP Copy via plink (PuTTY CLI) — fill in your values
REM plink -sshlog c:\logs\Ndmp.txt -logoverwrite -batch -ssh admin@<cluster-ip> -pw <password> run -node <node> ndmpcopy -sa <user>:<ndmp-pw> -da <user>:<ndmp-pw> <src-lif>:<src-path> <dst-lif>:<dst-path>
echo Edit this file with your cluster details before running.
pause
