# DiffusionBear 설치 및 점검

[DiffusionBear](https://github.com/Huntbae/DiffusionBear)(Apple Silicon Mac 전용 로컬 이미지 생성 앱) 설치와 점검 도구입니다.
`Huntbae/DiffusionBear` 저장소는 원본 `OuincheWinch/DiffusionBear` v0.4.2와 같은 내용으로 갱신되어 있습니다.

## 설치 (Mac 터미널)

```bash
set -e
cd ~/Downloads
curl -L -o DiffusionBear-0.4.2-arm64.zip \
  https://github.com/OuincheWinch/DiffusionBear/releases/download/v0.4.2/DiffusionBear-0.4.2-arm64.zip
echo "cde8d562fbbfaafa91de1acf8e80e36de2d8330b2824498569ec1c09b2a73308  DiffusionBear-0.4.2-arm64.zip" | shasum -a 256 -c -
ditto -x -k DiffusionBear-0.4.2-arm64.zip .
rm -rf /Applications/DiffusionBear.app
mv DiffusionBear.app /Applications/
xattr -cr /Applications/DiffusionBear.app
open /Applications/DiffusionBear.app
```

- 필요 조건: Apple Silicon(M1 이상), macOS 26.2 이상, 메모리 16GB 권장
- 해시값은 원본 v0.4.2 릴리스 노트에 공개된 값이며, 실제 배포 파일로 일치 여부를 확인했습니다.

## 설치 및 모델 점검

앱을 켠 상태에서 실행하면 앱이 인식하는 설치/미설치 모델 목록까지 나옵니다. 아무것도 설치하거나 지우지 않습니다.

```bash
curl -fsSL https://raw.githubusercontent.com/Huntbae/claude/claude/voicebox-repo-a7f94k/diffusionbear/check_install.sh -o check_install.sh
bash check_install.sh
```

점검 항목: macOS 버전·칩·메모리, 앱 버전·격리 속성·코드 서명, 실행 중인 앱의 모델 목록(설치 여부·용량), 디스크의 모델 파일(앱 데이터 폴더, Hugging Face 캐시), 최근 오류 로그.
