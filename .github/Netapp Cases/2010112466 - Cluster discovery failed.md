# NetApp Case Summary – 2010112466 (Cluster discovery failed)

## 🧾 Case Overview
- **Case Number:** 2010112466  
- **Customer:** Cognyte Software Ltd.  
- **System / Host:** THCNAORA1N1  
- **Product:** Active IQ Unified Manager (AIQUM) 9.14  
- **Timeframe:** July–August 2024  
- **Topic:** Cluster discovery failure after upgrade

---

## ❓ Problem Description
- AIQUM reported: **“Cluster discovery failed. Rediscover the cluster after resolving the issue.”**
- Issue appeared **after upgrading to version 9.14**
- Discovery failed consistently and required manual rediscovery attempts

[1](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwBlIM2hzC3dSK2NkNgCby%2fuAAAAAAEMAAClyUzxQdXEQ6EoEmtUUKHpAAJwTT2cAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)[2](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwBlIM2hzC3dSK2NkNgCby%2fuAAAAAAEMAAClyUzxQdXEQ6EoEmtUUKHpAAJwTT2bAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)

---

## 🔍 Root Cause (NetApp-Confirmed)

- **Cloud Agent was enabled**
- AIQUM experienced **mTLS communication issues**
- Root cause matched **known NetApp bug: CAIQUM-6090**
- mTLS prevented proper communication between AIQUM and the ONTAP cluster

[1](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwBlIM2hzC3dSK2NkNgCby%2fuAAAAAAEMAAClyUzxQdXEQ6EoEmtUUKHpAAJwTT2cAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)[2](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwBlIM2hzC3dSK2NkNgCby%2fuAAAAAAEMAAClyUzxQdXEQ6EoEmtUUKHpAAJwTT2bAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)

---

## ✅ Resolution / Fix Applied

- **Disabled Cloud Agent**
- **Disabled mTLS**
- After applying the changes:
  - Cluster discovery succeeded
  - No further discovery failures observed

[1](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwBlIM2hzC3dSK2NkNgCby%2fuAAAAAAEMAAClyUzxQdXEQ6EoEmtUUKHpAAJwTT2cAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)[2](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwBlIM2hzC3dSK2NkNgCby%2fuAAAAAAEMAAClyUzxQdXEQ6EoEmtUUKHpAAJwTT2bAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)

---

## 📚 References / Known Issues

- **Bug ID:** CAIQUM-6090  
  - AIQUM cluster discovery issues when Cloud Agent and mTLS are enabled together  
- **Product:** Active IQ Unified Manager (AIQUM) 9.14

_(NetApp internal bug referenced in case notes)_

---

## 📌 Case Status
- Priority: P3  
- Case reviewed and solution validated remotely with customer
- **Case archived and closed**  
- Closure confirmed by customer (Yitzhak Bohadana)

[1](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwBlIM2hzC3dSK2NkNgCby%2fuAAAAAAEMAAClyUzxQdXEQ6EoEmtUUKHpAAJwTT2cAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)[2](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwBlIM2hzC3dSK2NkNgCby%2fuAAAAAAEMAAClyUzxQdXEQ6EoEmtUUKHpAAJwTT2bAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)

---

## 🧠 Executive Summary (Short)
After upgrading to AIQUM 9.14, cluster discovery failed due to a known mTLS issue (CAIQUM-6090) when the Cloud Agent was enabled. Disabling both Cloud Agent and mTLS fully resolved the issue, and the case was closed.
``