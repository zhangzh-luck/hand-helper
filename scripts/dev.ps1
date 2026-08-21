param([ValidateSet('backend','web')][string]$Target='backend')
if($Target -eq 'backend'){Set-Location "$PSScriptRoot\..\backend"; uvicorn app.main:app --reload}else{Set-Location "$PSScriptRoot\..\web"; npm run dev}
