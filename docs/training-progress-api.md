# Tab "Tiến trình" — API

Hai endpoint, đều nằm dưới `/v1`, đều yêu cầu `Authorization: Bearer <access token>`
và chỉ trả dữ liệu của chính người dùng trong token. Không có tham số user id ở
bất kỳ đâu.

## Vì sao hai endpoint mà không phải chín

Chỉ đúng một thứ trên trang đổi theo thao tác của người dùng: biểu đồ 12 tuần đổi
khi bấm chip môn thể thao. Nó được tách riêng để mỗi lần bấm chip chỉ tải 12 con
số. Tám phần còn lại không phụ thuộc môn, và đều đọc ra từ **một** lần quét
`workout_sessions` — tách thành tám endpoint là tám lần quét cùng một tập dữ liệu.

## Quy ước chung

- Số liệu ở đơn vị thô: mét, giây, phần trăm là số (29 = 29%). Việc viết
  "2,49 km" hay "23phút 14giây" là của giao diện.
- Ngày là `YYYY-MM-DD` theo **local_date** của bản ghi, tức ngày trên lịch của
  người dùng (múi giờ lấy từ hồ sơ). Không cần truyền timezone.
- Tuần bắt đầu **thứ Hai**; một tuần được gọi tên bằng `weekStart` (ngày thứ Hai).
- Thời điểm là epoch milliseconds (`achievedAt`).
- Lỗi theo định dạng chung của API:
  `{ "error": { "code": "VALIDATION", "message": "..." } }`, HTTP 400/401/404/500.

---

## `GET /v1/training/progress/weeks`

Biểu đồ 12 tuần + 3 số liệu của tuần đang chọn.

| Tham số | Kiểu | Mặc định | Ý nghĩa |
|---|---|---|---|
| `sport` | `all` hoặc mã môn (`running`, `walking`, `gym_strength`, …) | `all` | Lọc theo môn |
| `weeks` | int 4–52 | `12` | Số tuần trả về |

```json
{
  "sport": "running",
  "today": "2026-09-21",
  "weeks": [
    {
      "weekStart": "2026-07-06",
      "weekEnd": "2026-07-12",
      "distanceM": 0,
      "movingSeconds": 0,
      "elevationGainM": 0,
      "sessions": 0
    },
    "… 10 tuần nữa …",
    {
      "weekStart": "2026-09-21",
      "weekEnd": "2026-09-27",
      "distanceM": 2490,
      "movingSeconds": 1394,
      "elevationGainM": 18,
      "sessions": 1
    }
  ]
}
```

`weeks` luôn đủ số phần tử được yêu cầu, cũ → mới, phần tử cuối là tuần hiện tại.
Tuần không tập vẫn có bucket với giá trị 0 — biểu đồ vẽ điểm ở mức 0 chứ không
bỏ điểm, nên trục ngang luôn cách đều.

---

## `GET /v1/training/progress`

Mọi phần còn lại của tab.

```json
{
  "today": "2026-09-21",
  "focus": "stay_active",
  "sports": [
    { "code": "running", "sessions": 12 },
    { "code": "gym_strength", "sessions": 5 },
    { "code": "walking", "sessions": 2 }
  ],
  "streakWeeks": 6,
  "log": {
    "thisWeek": {
      "weekStart": "2026-09-21",
      "days": [{ "date": "2026-09-21", "seconds": 1394 }],
      "totalSeconds": 1394
    },
    "lastWeek": {
      "weekStart": "2026-09-14",
      "days": [
        { "date": "2026-09-14", "seconds": 0 },
        { "date": "2026-09-15", "seconds": 0 },
        { "date": "2026-09-16", "seconds": 4920 },
        { "date": "2026-09-17", "seconds": 0 },
        { "date": "2026-09-18", "seconds": 0 },
        { "date": "2026-09-19", "seconds": 0 },
        { "date": "2026-09-20", "seconds": 0 }
      ],
      "totalSeconds": 4920
    }
  },
  "suggestion": { "code": "recovery_run", "distanceM": 6000, "reason": "recent_session" },
  "prediction": {
    "distanceM": 5000,
    "currentSeconds": 2115,
    "baselineSeconds": 2285,
    "deltaSeconds": -170,
    "series": [
      { "date": "2026-08-28", "seconds": 2285 },
      { "date": "2026-09-09", "seconds": 2180 },
      { "date": "2026-09-18", "seconds": 2115 }
    ]
  },
  "zones": {
    "from": "2026-08-23",
    "to": "2026-09-21",
    "totalSeconds": 18000,
    "zones": [
      { "zone": 1, "seconds": 1800, "percent": 10 },
      { "zone": 2, "seconds": 3600, "percent": 20 },
      { "zone": 3, "seconds": 5220, "percent": 29 },
      { "zone": 4, "seconds": 3960, "percent": 22 },
      { "zone": 5, "seconds": 2520, "percent": 14 },
      { "zone": 6, "seconds": 900, "percent": 5 }
    ],
    "topZone": 3,
    "topPercent": 29,
    "deltaPercent": 19
  },
  "records": [
    { "distanceM": 10000, "seconds": 4814, "achievedAt": 1756000000000, "rank": 1 },
    { "distanceM": 5000, "seconds": 2263, "achievedAt": 1755000000000, "rank": 1 },
    { "distanceM": 1000, "seconds": 401, "achievedAt": 1754000000000, "rank": 1 }
  ],
  "monthRecap": { "month": "2026-08" },
  "monthly": {
    "thisMonth": {
      "month": "2026-09",
      "totalSeconds": 19740,
      "cumulativeSeconds": [0, 1800, 1800, "… một phần tử mỗi ngày tới hôm nay …"],
      "daysInMonth": 30
    },
    "lastMonth": {
      "month": "2026-08",
      "totalSeconds": 13980,
      "cumulativeSeconds": ["… đủ 31 phần tử …"],
      "daysInMonth": 31
    }
  }
}
```

### Từng trường

**`focus`** — trọng tâm tập luyện, một trong `improve_fitness`, `event_training`,
`stay_active`, `recovery`. Lưu ở `user_profiles.training_focus`. Sửa bằng
`PUT /v1/me/profile` với `{ "trainingFocus": "recovery" }`. Giá trị này cũng được
nạp vào ngữ cảnh của Trợ lý AI (kèm một dòng giải nghĩa), nên lời khuyên của trợ
lý đổi theo nó.

**`sports`** — các chip môn thể thao, dựng từ 12 tuần gần nhất của chính người
dùng, môn nhiều buổi nhất đứng trước. Giao diện tự thêm chip "Tất cả" ở đầu và
gom phần đuôi vào một menu chọn khi hàng chip quá dài.

**`streakWeeks`** — số tuần liên tiếp có ít nhất một buổi. Tuần hiện tại còn
trống thì không tính là đứt chuỗi (nó chưa xảy ra), đếm lùi từ tuần trước.

**`log`** — hai hàng chấm của thẻ "Nhật ký tập luyện". `thisWeek.days` chỉ tới
hôm nay; `lastWeek.days` luôn đủ 7 ngày, thứ Hai trước.

**`suggestion`** — buổi tập gợi ý, tính bằng luật từ khối lượng chạy 4 tuần gần
nhất (app không có giáo án). `code` ∈ `first_run`, `recovery_run`, `base_run`,
`tempo_run`, `long_run`; `reason` là lý do luật chọn nó. Tên và mô tả buổi tập do
**giao diện** dịch từ `code` — đó là lý do backend không trả chuỗi hiển thị: app
đã có hệ thống ngôn ngữ vi/en, backend không cần bản sao thứ hai.

**`prediction`** — thời gian 5 km dự đoán theo công thức Riegel
(`t2 = t1 × (d2/d1)^1.06`) trên các buổi chạy ≥ 1,5 km trong 30 ngày qua. Mỗi
ngày có buổi chạy đạt chuẩn cho một điểm, giá trị là **kỷ lục dự đoán tốt nhất
tính tới ngày đó**, nên đường chỉ đi theo hướng tốt lên. `deltaSeconds` âm =
nhanh hơn. `null` khi chưa có buổi chạy nào đủ điều kiện.

**`zones`** — thời gian theo vùng nhịp tim trong 30 ngày qua, `deltaPercent` so
với 30 ngày liền trước đó của **cùng vùng** đang dẫn đầu. Chỉ có số khi buổi tập
mang theo dữ liệu nhịp tim; không có thì `totalSeconds` = 0 và `topZone` = null.

**`records`** — tối đa 3 kỷ lục `fastest_distance` đang giữ, cự ly lớn trước.
`rank` luôn là 1: mỗi dòng ở đây là kỷ lục hiện hành của cự ly đó. Trường vẫn tồn
tại vì thẻ vẽ huy chương, mà huy chương thì cần một thứ hạng.

**`monthly`** — thời gian tích luỹ theo ngày. `thisMonth.cumulativeSeconds` dừng
ở hôm nay; tháng trước đủ số ngày. `daysInMonth` cho giao diện biết trục ngang
dài bao nhiêu.
