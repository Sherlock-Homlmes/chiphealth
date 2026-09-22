# Màn "Chi tiết buổi chạy" — API

Ba endpoint, đều nằm dưới `/v1`, đều cần `Authorization: Bearer <access token>`
và chỉ trả dữ liệu của chính người dùng trong token. Không có tham số user id ở
bất kỳ đâu; một buổi tập không thuộc về người gọi trả `404`.

Mọi số liệu đều ở đơn vị thô: mét, giây, giây trên mỗi km, phần trăm dạng số.
Giao diện lo phần định dạng ("10,60 km", "1:22:16", "7:45 /km").

## Vì sao ba endpoint

| Endpoint | Vì sao tách |
|---|---|
| `GET /workouts/:id` | Toàn bộ phần chữ và số của bottom sheet. Tất cả đọc ra từ một buổi tập và các bảng con của nó, nên gộp một lần gọi; tách ra là tách cùng một lần đọc thành tám. |
| `GET /workouts/:id/track` | Chuỗi điểm theo quãng đường. Nặng hơn phần còn lại một bậc, nằm trong R2 chứ không phải D1, và số điểm cần lấy khác nhau tuỳ màn — nên nó có tham số và có nhịp tải riêng. |
| `GET /workouts/:id/insight/:kind` | Phần duy nhất phải chờ model. Sheet vẽ xong số liệu ngay; mỗi thẻ nhận xét tự điền khi câu của nó về, hoặc tự ẩn nếu không về. |

Ngoài ra `POST /workouts/:id/bookmark` để lưu / bỏ lưu buổi chạy.

## `GET /workouts/:id`

Trả bản ghi buổi tập, kèm mọi thứ dẫn xuất từ nó.

```json
{
  "id": "01a0c696-e93a-74db-bf2c-d73c14ab3868",
  "activityTypeId": 1,
  "title": "Chạy bộ buổi tối",
  "startedAt": 1789842120000,
  "localDate": "2026-09-21",
  "durationSeconds": 5099,
  "movingSeconds": 5099,
  "distanceM": 10586.2,
  "avgPaceSecPerKm": 482,
  "bestPaceSecPerKm": 401,
  "elevationGainM": 56.4,
  "elevationMaxM": 17,
  "gapSecPerKm": 482,
  "steps": 13597,
  "avgCadence": 160,
  "avgHeartRate": null,
  "maxHeartRate": null,
  "caloriesBurnedKcal": 712,
  "isBookmarked": true,
  "notes": null,
  "photoAssetIds": [],
  "stream": {
    "encodedPolyline": "}uowAqfl...",
    "sampleCount": 5100,
    "boundsJson": "{\"minLat\":20.60,\"minLng\":105.95,\"maxLat\":20.64,\"maxLng\":105.99}",
    "hasGps": true,
    "hasHeartRate": false
  },
  "splits": [
    { "splitIndex": 1, "splitDistanceM": 1000, "elapsedSeconds": 467,
      "movingSeconds": 467, "avgPaceSecPerKm": 467, "elevationGainM": 3.1,
      "avgHeartRate": null }
  ],
  "zones": [],
  "paceZones": [
    { "zoneNumber": 1, "kind": "pace", "secondsInZone": 686, "percentOfSession": 13.6 }
  ],
  "paceZoneRanges": [
    { "zoneNumber": 6, "minSecPerKm": null, "maxSecPerKm": 336 },
    { "zoneNumber": 5, "minSecPerKm": 336, "maxSecPerKm": 358 },
    { "zoneNumber": 4, "minSecPerKm": 358, "maxSecPerKm": 383 },
    { "zoneNumber": 3, "minSecPerKm": 383, "maxSecPerKm": 431 },
    { "zoneNumber": 2, "minSecPerKm": 431, "maxSecPerKm": 498 },
    { "zoneNumber": 1, "minSecPerKm": 498, "maxSecPerKm": null }
  ],
  "paceZoneBasisSeconds": 1917,
  "bestEfforts": [
    { "distanceM": 400, "elapsedSeconds": 175.8, "startDistanceM": 2600,
      "endDistanceM": 3000, "rank": 2 },
    { "distanceM": 10000, "elapsedSeconds": 4825.1, "startDistanceM": 0,
      "endDistanceM": 10000, "rank": 1 }
  ],
  "effortCounters": { "bestEver": 1, "achievements": 7 },
  "predictions": [
    { "distanceM": 5000, "seconds": 1917 },
    { "distanceM": 10000, "seconds": 4825 },
    { "distanceM": 21097, "seconds": 10646 }
  ],
  "predictionImproved": [
    { "distanceM": 10000, "seconds": 4825, "improvedBySeconds": 81 }
  ],
  "sets": []
}
```

Vài chỗ đáng nói:

- **`bestEfforts` không phải kỷ lục.** Kỷ lục (`/training/records`) là thành tích
  tốt nhất đang đứng; một `bestEffort` là những gì **buổi này** làm được ở một
  cự ly chuẩn, kèm thứ hạng nó chiếm trên bảng **tại thời điểm chạy**. Thứ hạng
  đó được đóng băng có chủ đích: một buổi nhanh hơn về sau không viết lại những
  gì trang của buổi này đã nói hôm đó. `startDistanceM` / `endDistanceM` là vị
  trí của đoạn đó trên tuyến — bản đồ gắn huy chương vào đấy.
  Cự ly được chấm: 400, 805, 1000, 1609, 3219, 5000, 10000, 15000, 21097, 42195 m.
- **`effortCounters`**: `bestEver` là số hạng nhất, `achievements` là số hạng
  từ 10 trở lên. Ứng dụng không có thử thách nên không có bộ đếm thứ ba.
- **`predictionImproved`** chỉ chứa những dự đoán mà **buổi này** cải thiện, xếp
  cự ly gần với quãng đường đã chạy lên trước. Rỗng thì màn ẩn cả thẻ.
- **`paceZoneRanges`** tính lại mỗi lần đọc từ `paceZoneBasisSeconds` — nó là
  hàm thuần của dự đoán 5 km nên không cần lưu. Z6 không có cận dưới, Z1 không
  có cận trên.
- **`zones`** là vùng **nhịp tim**, rỗng khi bản ghi không mang nhịp tim; màn
  hiện empty state hướng dẫn kết nối máy đo.

### Các số được tính thế nào

| Số | Cách tính |
|---|---|
| `gapSecPerKm`, chuỗi GAP | Chia tuyến thành đoạn ≥ 100 m, mỗi đoạn lấy độ dốc `Δcao/Δdài`, quy về nhịp độ tương đương mặt phẳng theo chi phí năng lượng chạy dốc của Minetti (`cost(i)/cost(0)`, kẹp độ dốc ở ±45%). Trung bình có trọng số theo quãng đường, không phải trung bình các nhịp độ. Ngưỡng 100 m là để một mét nhiễu độ cao GPS không thành vách núi. |
| `bestEfforts[].elapsedSeconds` | Cửa sổ trượt trên chuỗi (quãng đường, thời gian) tích luỹ, xét cả họ "cửa sổ kết thúc tại nút" và "cửa sổ bắt đầu tại nút" — nên một PR 5 km nằm giữa hai mốc km vẫn tìm ra. |
| `bestEfforts[].rank` | `1 +` số thành tích của chính người dùng, cùng môn, cùng cự ly, nhanh hơn thành tích này, đếm tại thời điểm ghi. |
| `predictions[].seconds` | Riegel `t2 = t1 × (d2/d1)^1.06` từ bảng thành tích tốt nhất 365 ngày gần nhất. Mốc phải nằm trong khoảng ¼ đến 4 lần cự ly đích, và **mốc gần cự ly đích nhất** thắng chứ không phải mốc cho ra con số đẹp nhất — sai số ngoại suy tăng theo tỉ lệ cự ly. |
| `paceZoneRanges` | Neo vào nhịp độ của dự đoán 5 km, chia theo phần trăm **tốc độ** ngưỡng: 114 / 107 / 100 / 89 / 77%. |
| `paceZones[].percentOfSession` | Phần trăm **thời gian chạy**, không phải thời gian đồng hồ: đoạn chậm hơn 30:00/km bị coi là đang đứng và không vào mẫu số. |
| `steps` | `avgCadence × phút di chuyển`. Không có cadence thì `null` và ô đó bị ẩn. |

Tất cả được tính **một lần** lúc nạp stream (`PUT /workouts/:id/stream`) cùng
với chia chặng và kỷ lục, rồi ghi xuống bảng. Cắt buổi tập (`POST
/workouts/:id/crop`) chạy lại đúng đường đó trên phần còn lại.

## `GET /workouts/:id/track?points=400`

Chuỗi điểm của tuyến. `points` mặc định 1500, tối đa 1500, tối thiểu 50: màn
chi tiết xin 400, màn cắt xin tối đa.

```json
{
  "items": [
    { "t": 0, "lat": 20.6274277, "lng": 105.9700184, "d": 0,
      "ele": 6.1, "hr": null, "pace": 468, "gap": 441 }
  ]
}
```

`t` là giây kể từ mẫu đầu, `d` là mét tích luỹ. `pace` và `gap` đo trên đoạn từ
**điểm trả về trước đó** chứ không phải giữa hai mẫu thô: ở tần số 1 Hz người
chạy đi được khoảng ba mét, và nhịp độ tính trên ba mét là nhiễu GPS. Điểm đầu
mượn nhịp độ của điểm thứ hai để đường biểu đồ không bắt đầu từ số không.

Cùng một endpoint phục vụ cả phát lại tuyến, màn cắt và các biểu đồ — chúng cần
đúng một chuỗi ở ba độ phân giải khác nhau.

## `POST /workouts/:id/bookmark`

```json
{ "bookmarked": true }   →   { "bookmarked": true }
```

Là một cờ trên buổi tập chứ không phải bảng riêng: chỉ chủ sở hữu mới nhìn thấy
buổi tập của mình, nên không có bên thứ hai nào cần một dòng bookmark.

## Định dạng lỗi

Chung cho toàn bộ API:

```json
{ "error": { "code": "NOT_FOUND", "message": "Workout not found", "details": null } }
```

`VALIDATION_ERROR` 400 · `UNAUTHENTICATED` 401 · `FORBIDDEN` 403 ·
`NOT_FOUND` 404 · `CONFLICT` 409 · `RATE_LIMITED` 429 ·
`UPSTREAM_AI_ERROR` 502 · `INTERNAL` 500.

---

# Athlete Intelligence — sinh nhận xét bằng LLM

## `GET /workouts/:id/insight/:kind`

`kind` ∈ `overview` | `pace` | `zones`.

```json
{ "kind": "pace",
  "body": "Nhịp độ dao động mạnh từ 7:20/km đến 11:23/km, nửa sau chậm hơn 55 giây mỗi km và kết thúc ở 7:52/km." }
```

`body` là `null` khi model quá chậm, lỗi, hoặc trả về thứ không dùng được —
**không** phải lỗi HTTP. Thẻ trên màn hình ẩn đi; một tấm thẻ chứa thông báo lỗi
ở chỗ đáng lẽ là một câu văn thì tệ hơn là không có thẻ nào.

## Dữ liệu vào

Backend tính sẵn và chỉ đưa model đúng những gì câu nhận xét được phép nói tới —
đưa cả bản ghi buổi tập thì model dựng chuyện quanh những trường nó nhận ra.
Số liệu được **định dạng sẵn** ("7:47/km", "1:25:00", "10.59 km") chứ không phải
giây thô, vì lý do ở mục "Hai điều phải học" bên dưới.

```jsonc
// overview
{ "quang_duong": "10.59 km", "thoi_gian_di_chuyen": "1:25:00",
  "nhip_do_tb": "8:02/km", "do_cao_tang": "56 m",
  "nhip_do_dieu_chinh_doc": "8:02/km",
  "thanh_tich": [{ "cu_ly": "10 km", "thoi_gian": "1:20:25", "hang": 1 }],
  "du_doan":  [{ "cu_ly": "10 km", "thoi_gian": "1:20:25" }] }

// pace — hình dạng buổi chạy, không phải cả bảng chặng
{ "quang_duong": "10.59 km", "thoi_gian_di_chuyen": "1:25:00",
  "nhip_do_tb": "8:02/km", "thoi_gian_thuc_te": "1:25:00", "so_chang": 11,
  "chang_dau": "7:47/km", "chang_cuoi": "7:28/km",
  "chang_nhanh_nhat": "7:19/km", "chang_cham_nhat": "11:25/km",
  "nua_dau_so_voi_nua_sau": "nửa sau chậm hơn 55 giây mỗi km" }

// zones
{ "quang_duong": "10.59 km", "thoi_gian_di_chuyen": "1:25:00",
  "nhip_do_tb": "8:02/km",
  "phan_tram_thoi_gian_moi_vung": { "Z1": "13.6%", "Z2": "86.4%" },
  "du_doan_5km": "31:57" }
```

## Prompt

Ba file, nằm cạnh mọi prompt khác của backend
(`src/prompts/workout/`, nạp qua `PROMPTS`, điền `{{biến}}` bằng `renderPrompt`):

- `insight_system.md` — vai huấn luyện viên, ngôn ngữ `{{language}}` (lấy từ cài
  đặt tài khoản, không phải từ token), và các ràng buộc: một câu ngắn; **chỉ**
  được dùng con số có trong dữ liệu; không bịa so sánh trừ khi dữ liệu có thứ
  hạng hoặc mức cải thiện; văn bản thuần; trả về đúng câu nhận xét.
- `insight_user.md` — `{{focus}}` (góc nhìn) + `{{data}}` (JSON ở trên).
- `insight_focus.md` — một mục `## overview` / `## pace` / `## zones` mô tả góc
  nhìn, đọc ra bằng `promptSections`.

## Đầu ra

Một câu văn bản thuần. Hậu xử lý (`tidyInsight`) bóc dấu ngoặc bao ngoài, bỏ
markdown, gộp xuống dòng; rỗng hoặc dài quá 220 ký tự thì coi như thất bại.

## Cache

Bảng `workout_insights`, khoá chính `(workout_session_id, kind, language)`.
`input_hash` là SHA-256 (16 byte đầu) của đúng khối dữ liệu đã đưa model. Đọc
lại màn hình không sinh lại; cắt buổi tập hoặc nạp lại stream làm số liệu đổi,
hash đổi, câu được sinh lại. Đổi ngôn ngữ trong Cài đặt cho ra một dòng riêng
chứ không đè lên dòng cũ.

## Lỗi và thời gian chờ

`AI_WORKOUT_INSIGHT_TIMEOUT_MS` (mặc định 90 000) bọc quanh lời gọi model;
`AI_WORKOUT_INSIGHT_MAX_TOKENS` (mặc định 4096) là ngân sách token. Quá giờ,
lỗi mạng, hay câu trả về không dùng được đều cho ra `body: null` và **không**
ghi cache — lần mở sau thử lại.

## Hai điều phải học về model đang dùng

Cả hai đều biểu hiện giống hệt nhau — `finish_reason: "length"` với
`message.content` rỗng — nên ghi lại ở đây để lần sau không mất một giờ:

1. **Model suy luận bằng đúng ngân sách token nó dùng để trả lời.** Ở 256 token
   nó tiêu sạch vào phần suy nghĩ và trả về chuỗi rỗng. 4096 mới đủ cho một câu.
2. **Đừng đặt giới hạn số từ.** Luật "tối đa 25 từ" khiến nó ngồi đếm từng từ
   trong phần suy luận ("và(20) chặng(21) cuối(22)...") cho tới khi hết token.
   Luật hiện tại nói "một câu ngắn, dài cỡ một dòng, không đếm từ".

Đưa số đã định dạng sẵn cũng thuộc nhóm này: model nhận 467 sẽ tự quy ra
7:47/km ngay trong phần suy luận, mười một lần liền.

## Dữ liệu để thử

`node backend/scripts/dev-seed-run.mjs` tạo ba buổi chạy trên tài khoản dev qua
đúng đường HTTP mà ứng dụng đi: một buổi dài chậm 10,4 km, một buổi tempo 5,2 km,
và buổi 10,60 km quanh Duy Tiên (tuyến vòng, có đoạn chạy lặp lại, chặng 9 rất
chậm). Kết quả: buổi cuối giữ PR 10 km, đứng hạng 2 ở các cự ly ngắn sau buổi
tempo, và cải thiện dự đoán 10 km 81 giây — đủ để mọi khối trên màn hình có thứ
để vẽ.
