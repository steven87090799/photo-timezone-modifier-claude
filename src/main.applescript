-- ============================================================
-- 📸 MAC 時區注入工具 v2.1
-- v2.1 修復(建立在 v2.0 之上):
--   [Bug1‧高] 防呆模式「全部命中」時 exiftool 以 exit 2 結束,
--             AppleScript do shell script 會把它當成例外丟出 →
--             改用 exit code 分流(2=全部已有時區、0=成功、1=真錯誤),
--             不再彈出「非預期錯誤」。順手刪掉永遠對不到的字串偵測。
--   [Bug2‧高] 拖放「資料夾」時 kind is "folder" 在繁中系統失效
--             (資料夾的 kind 是「檔案夾」)→ 改用 shell test -d 判斷,
--             完全不受系統語言影響。
--   [Bug3‧中] 預覽視窗的「取消」鈕原本沒作用 → 補上 cancel button,
--             並移到 try 之外,避免使用者取消被誤報成「讀取失敗」。
--   [強化]   寫入指令加 2>&1 擷取警告;可攜版 ExifTool 改用 perl 執行
--             + chmod +x + 下載後驗證,避免 zip 沒保留執行權限而無法執行。
-- 說明:本工具只寫入「時區偏移」標籤(OffsetTime*),不會改動 DateTimeOriginal,
--       因此 Immich/Apple Photos 能以「當地時間 − 偏移 = 正確 UTC」排序。
--       UTC 請選 +00:00(EXIF 規格不接受 "Z")。
-- ============================================================

-- 【模式 A:雙擊打開程式】
on run
	set modeChoice to choose from list {"選取單張/多張照片", "選取照片資料夾"} with prompt "請選擇處理對象:" default items {"選取單張/多張照片"}
	if modeChoice is false then return
	
	if item 1 of modeChoice is "選取單張/多張照片" then
		set selectedFiles to choose file with prompt "請選擇照片檔案 (支援 ARW 原始檔,可複選):" with multiple selections allowed
		set theItems to filterImages(selectedFiles)
	else
		set selectedFolder to choose folder with prompt "請選擇照片資料夾:"
		tell application "Finder"
			set allFiles to (every file of selectedFolder) as alias list
		end tell
		set theItems to filterImages(allFiles)
		if (count of theItems) is 0 then
			display dialog "資料夾內沒有符合格式的圖檔 (.arw, .jpg, .tif)!" buttons {"確定"} with icon caution
			return
		end if
	end if
	
	if (count of theItems) is 0 then
		display dialog "未選取任何有效的圖檔 (.arw, .jpg, .tif)!" buttons {"確定"} with icon caution
		return
	end if
	
	processPhotos(theItems)
end run

-- 【模式 B:直接拖放檔案/資料夾到 App 圖示上】
on open draggedItems
	set allFiles to {}
	repeat with currentItem in draggedItems
		set itemAlias to (currentItem as alias)
		set itemPath to POSIX path of itemAlias
		-- 用 test -d 判斷資料夾/卷宗,完全不受系統語言影響(繁中系統 kind = 「檔案夾」會失效)
		if (do shell script "test -d " & quoted form of itemPath & " && echo Y || echo N") is "Y" then
			tell application "Finder"
				set allFiles to allFiles & ((every file of itemAlias) as alias list)
			end tell
		else
			set end of allFiles to itemAlias
		end if
	end repeat
	set theItems to filterImages(allFiles)
	if (count of theItems) is 0 then
		display dialog "拖入的項目中沒有符合格式的圖檔 (.arw, .jpg, .tif)!" buttons {"確定"} with icon caution
		return
	end if
	processPhotos(theItems)
end open

-- 【智慧過濾模組】
on filterImages(fileList)
	set filteredList to {}
	tell application "Finder"
		repeat with aFile in fileList
			try
				set ext to name extension of aFile
				if ext is in {"arw", "ARW", "jpg", "JPG", "jpeg", "JPEG", "tif", "TIF", "tiff", "TIFF"} then
					set end of filteredList to (aFile as alias)
				end if
			end try
		end repeat
	end tell
	return filteredList
end filterImages

-- 【自動下載 ExifTool 引擎模組】
on getExifToolPath()
	-- 1) 系統已安裝(Homebrew 或 /usr/local)
	try
		set sysExif to do shell script "export PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH; command -v exiftool"
		if sysExif is not "" then return "exiftool"
	end try
	
	set portablePath to (POSIX path of (path to home folder)) & ".exiftool_portable/exiftool-master/exiftool"
	
	-- 2) 可攜版已下載:用 perl 執行,避開 zip 未保留執行權限的問題
	try
		do shell script "test -f " & quoted form of portablePath
		return "perl " & quoted form of portablePath
	end try
	
	-- 3) 首次下載
	display dialog "首次啟動需要下載「ExifTool 核心引擎」(約 15MB)。" buttons {"開始下載並執行"} default button 1 with icon note giving up after 15
	set downloadScript to "APP_DIR=\"$HOME/.exiftool_portable\"; mkdir -p \"$APP_DIR\"; curl -sL https://github.com/exiftool/exiftool/archive/refs/heads/master.zip -o \"$APP_DIR/exiftool.zip\"; unzip -q -o \"$APP_DIR/exiftool.zip\" -d \"$APP_DIR/\"; chmod +x \"$APP_DIR/exiftool-master/exiftool\" 2>/dev/null || true"
	do shell script downloadScript
	try
		do shell script "test -f " & quoted form of portablePath
	on error
		error "ExifTool 下載失敗,請確認網路連線後再試一次。"
	end try
	return "perl " & quoted form of portablePath
end getExifToolPath

-- 【核心處理與閃電批次邏輯】
on processPhotos(targetItems)
	set envPath to "export PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH; "
	
	try
		set toolCmd to getExifToolPath()
	on error errMsg
		display dialog "引擎錯誤:" & return & errMsg buttons {"確定"} with icon stop
		return
	end try
	
	set totalItemsCount to count of targetItems
	set firstItemPath to POSIX path of (item 1 of targetItems)
	
	-- 掃描:第一張深度資訊 + 全批次「缺時區」統計
	try
		set exifFields to " -Make -Model -SerialNumber -LensModel -DateTimeOriginal -CreateDate -OffsetTimeOriginal -ImageSize -FileType -ExposureTime -FNumber -ISO -FocalLength"
		set cmdExif to envPath & toolCmd & exifFields & " " & quoted form of firstItemPath
		set detailedExifReport to do shell script cmdExif
		
		-- 組出所有檔案路徑(供統計與寫入共用)
		set pathString to ""
		repeat with currentItem in targetItems
			set pathString to pathString & " " & quoted form of (POSIX path of currentItem)
		end repeat
		
		-- 統計缺少 OffsetTimeOriginal 的檔案數(接 wc,故 exit code 一定為 0,不會誤判)
		set countMissingTZ to do shell script envPath & toolCmd & " -if 'not $OffsetTimeOriginal' -p '$filename' -q" & pathString & " | wc -l | tr -d ' '"
		
		if countMissingTZ is "0" then
			set tzAlert to "✅ 安全檢查:全部 " & totalItemsCount & " 張相片均已內建時區標籤,無需補齊。"
		else
			set tzAlert to "⚠️ 安全警告:" & totalItemsCount & " 張中有 " & countMissingTZ & " 張【缺乏時區標籤】,極易引發時間錯亂!"
		end if
		
		set infoMsg to "【首張相片 EXIF 中繼資料深度檢查】" & return & ¬
			"--------------------------------------------------" & return & ¬
			detailedExifReport & return & ¬
			"--------------------------------------------------" & return & ¬
			tzAlert & return & return & ¬
			"📦 檔案統計:本次共選取了 " & totalItemsCount & " 個圖檔。" & return & ¬
			"是否開始執行後續時區寫入程序?"
	on error errMsg
		display dialog "讀取失敗:" & return & errMsg buttons {"確定"} with icon stop
		return
	end try
	
	-- 預覽確認(放在 try 外:按「取消」會靜默結束,不會被誤報成「讀取失敗」)
	display dialog infoMsg buttons {"取消", "下一步"} default button "下一步" cancel button "取消" with icon note
	
	-- 國家化時區選單(UTC 一律以 +00:00 表示,符合 EXIF 規格)
	set timezoneList to {¬
		"-12:00 (貝克島/國際換日線西)", "-11:00 (美屬薩摩亞/紐埃)", "-10:00 (美國夏威夷/大溪地)", "-09:00 (美國阿拉斯加)", ¬
		"-08:00 (加拿大溫哥華/美國洛杉磯/舊金山)", "-07:00 (美國丹佛/鹽湖城/鳳凰城)", "-06:00 (美國芝加哥/休士頓/墨西哥城)", ¬
		"-05:00 (美國紐約/加拿大多倫多/秘魯利馬)", "-04:00 (智利聖地牙哥/玻利維亞/巴拉圭)", "-03:00 (巴西聖保羅/阿根廷布宜諾斯艾利斯)", ¬
		"-02:00 (南喬治亞島與南三明治群島)", "-01:00 (維德角共和國/亞速爾群島)", "+00:00 (英國倫敦/葡萄牙里斯本/冰島/UTC)", ¬
		"+01:00 (法國巴黎/德國柏林/義大利羅馬/西班牙)", "+02:00 (希臘雅典/埃及開羅/烏克蘭/南非)", "+03:00 (俄羅斯莫斯科/沙烏地阿拉伯/土耳其)", ¬
		"+04:00 (阿聯杜拜/阿曼/高加索地區)", "+05:00 (巴基斯坦/馬爾地夫/烏茲別克)", "+06:00 (孟加拉達卡/不丹/哈薩克)", ¬
		"+07:00 (泰國曼谷/越南河內/印尼雅加達)", "+08:00 (台灣台北/香港/新加坡/北京/馬來西亞)", "+09:00 (日本東京/韓國首爾/帛琉)", ¬
		"+10:00 (澳洲雪梨/墨爾本/關島/海參崴)", "+11:00 (所羅門群島/新喀里多尼亞/瓦努阿圖)", "+12:00 (紐西蘭奧克蘭/斐濟/馬紹爾群島)", ¬
		"+13:00 (薩摩亞/東加王國/鳳凰群島)", "+14:00 (吉里巴斯聖誕島)"}
	
	set selectedTZ to choose from list timezoneList with prompt "請選擇欲寫入的目標時區:" default items {"+08:00 (台灣台北/香港/新加坡/北京/馬來西亞)"}
	if selectedTZ is false then return
	set tzValue to text 1 thru 6 of (item 1 of selectedTZ)
	
	set switchDialog to display dialog "【模式選擇:強制硬寫時區開關】" & return & return & ¬
		"⚠️ 預設防呆模式:僅針對「缺乏時區」的相片進行安全補齊。" & return & ¬
		"🔥 強制硬寫模式:不管相片原本有沒有時區,通通強制覆寫為 " & tzValue & "。" buttons {"關閉 (維持防呆保護)", "開啟 (強制全面硬寫)"} default button "關閉 (維持防呆保護)" with icon caution
	
	set forceOverwrite to false
	if button returned of switchDialog is "開啟 (強制全面硬寫)" then set forceOverwrite to true
	
	-- 組裝寫入指令:
	--   單等號 = 才是正確的 ExifTool 寫入語法(雙等號 == 會把值當成 =+08:00)
	--   '-OffsetTime*=' 萬用字元會一次建立/覆寫三個偏移標籤(即使原本不存在)
	--   2>&1 把 ExifTool 警告一併收進來;結尾印出真正的 exit code 供分流判斷
	if forceOverwrite is true then
		set coreCmd to toolCmd & " '-OffsetTime*=" & tzValue & "' -overwrite_original" & pathString
	else
		set coreCmd to toolCmd & " -if 'not $OffsetTimeOriginal' '-OffsetTime*=" & tzValue & "' -overwrite_original" & pathString
	end if
	set writeCmd to envPath & coreCmd & " 2>&1; echo \"__EXIT__:$?\""
	
	display notification "正在全速注入 " & tzValue & " 時區,請稍候..." with title "時區管線發動中 🚀"
	
	try
		set engineOutput to do shell script writeCmd
	on error errMsg
		-- 走到這裡通常是 shell 本身啟動失敗(如指令找不到),才是真正的例外
		display dialog "引擎啟動失敗:" & return & errMsg buttons {"確定"} with icon stop
		return
	end try
	
	-- 解析輸出與 exit code(最後一段 __EXIT__:N)
	set tid to AppleScript's text item delimiters
	set AppleScript's text item delimiters to "__EXIT__:"
	set outParts to text items of engineOutput
	set AppleScript's text item delimiters to tid
	set cleanOutput to item 1 of outParts
	set engineExit to "0"
	if (count of outParts) > 1 then set engineExit to item 2 of outParts
	
	-- exit code 分流:
	--   2 = -if 條件對「所有」檔案皆不成立 → 全部本來就有時區(防呆攔截)
	--   1 = 真正的寫入錯誤
	--   0 = 成功(含「部分更新、部分已有」的混合批次)
	if engineExit is "2" then
		display notification "防呆機制已啟動,未修改任何相片。" with title "🛡️ 檔案受到安全保護"
		display dialog "【時區防呆檢查完成】" & return & return & ¬
			"🛡️ 報告:所有 " & totalItemsCount & " 張相片均已內建時區標籤,防呆機制全數攔截保護,無任何檔案被覆寫。" buttons {"太棒了"} default button 1 with icon note
	else if engineExit is "0" then
		display notification "已成功處理 " & totalItemsCount & " 張相片!" with title "✨ 時區注入完畢!" subtitle ("模式:" & (button returned of switchDialog))
		display dialog "【時區極速寫入完成】" & return & return & ¬
			"引擎執行報告:" & return & "✅ " & cleanOutput & return & return & ¬
			"總計掃描檔案數:" & totalItemsCount & " 張" buttons {"完成"} default button 1 with icon note
	else
		display dialog "⚠️ 寫入時發生錯誤(exit " & engineExit & "):" & return & return & cleanOutput buttons {"確定"} with icon stop
	end if
end processPhotos
