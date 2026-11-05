# FrontCamVideo

Tweak thay camera trước bằng một video có sẵn (Instagram iOS).

## Cách dùng

1. Cài tweak.
2. Copy video vào một trong các đường dẫn:
```text
/var/jb/var/mobile/Documents/FrontCam.mp4
/var/jb/var/mobile/Documents/FrontCam.mov
/var/jb/var/mobile/Documents/FrontCam/FrontCam.mov
/var/mobile/Documents/FrontCam.mov
```

Hoặc đặt bất kỳ file `.mp4`/`.mov` nào trong:
```text
/var/jb/var/mobile/Documents/FrontCam/
```

Cũng có thể tạo file `path.txt` trong thư mục `FrontCam` chứa đường dẫn tuyệt đối tới video.
3. Mở Instagram → vào camera/story → chọn camera trước. Video sẽ lặp làm feed camera trước.

Khuyến nghị: video dọc 1080x1920, H.264/HEVC, 30fps, không cần audio.

## Đổi đường dẫn / tắt mirror

Tweak đọc `NSUserDefaults` suite `com.bluek.frontcam`:

```bash
defaults write com.bluek.frontcam Enabled -bool true
defaults write com.bluek.frontcam Path "/var/jb/var/mobile/Documents/myvideo.mp4"
defaults write com.bluek.frontcam Mirror -bool true
```

Tắt mirror:
```bash
defaults write com.bluek.frontcam Mirror -bool false
```

Sau khi đổi video/preferences, kill Instagram rồi mở lại.

## Log

```text
/var/jb/var/mobile/Documents/FrontCam/FrontCam.log
```

Nếu không thấy video, xem log để biết file có được tìm thấy, asset có load được không, format camera có hỗ trợ không.

## Giới hạn

- Chỉ thay feed `AVCaptureVideoDataOutput` (preview + frame app nhận được).
- Nếu app ghi video bằng `AVCaptureMovieFileOutput` thì bản ghi có thể vẫn dùng camera thật.
- Video được scale aspect-fill vào khung camera; video khác tỷ lệ sẽ bị crop.
- Audio không bị thay.
