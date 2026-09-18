<!--
Mô tả tool cho Trợ lý AI. Mỗi mục "## <tên_tool>" là description gửi cho model trong định nghĩa tool
(services/agent/tools.ts đọc bằng promptSections). Schema tham số nằm trong code cạnh phần thực thi.
Tool có tên create_/update_/delete_/log_/add_ là tool GHI: chỉ tạo đề xuất chờ người dùng xác nhận.
Thêm tool mới => thêm mục ở đây; thiếu mục thì unit test báo lỗi.
-->
## get_profile
Hồ sơ người dùng: tuổi, giới tính, chiều cao, cân nặng mới nhất, mức vận động, mục tiêu đang theo, bệnh nền, BMR/TDEE hôm nay và mức calo tự đặt (nếu có).

## get_day_summary
Tổng quan một ngày: calo nạp, calo đốt khi tập, TDEE, cân bằng calo, macro; danh sách bữa ăn (có meal_id); các buổi tập (có workout_id); giấc ngủ kết thúc vào sáng ngày đó (có sleep_id).

## get_nutrition_range
Calo và macro theo từng ngày trong một khoảng (tối đa 62 ngày) — dùng để xem xu hướng, trung bình, ngày vượt/thiếu calo.

## list_meals
Liệt kê bữa ăn trong một khoảng ngày (tối đa 31 ngày), mới nhất trước: meal_id, loại bữa, giờ ăn, tên món, calo, macro, trạng thái phân tích.

## get_meal
Chi tiết một bữa ăn: từng thành phần (item_id, tên, gram, calo, protein, carbs, fat). Dùng trước khi sửa/xoá thành phần.

## search_foods
Tra kho thực phẩm theo tên: calo và macro trên 100 g. Dùng khi tư vấn món ăn hoặc lên thực đơn.

## list_workouts
Liệt kê buổi tập trong một khoảng ngày (tối đa 62 ngày): workout_id, môn, thời điểm bắt đầu, thời lượng, quãng đường, calo, nhịp tim.

## list_activity_types
Danh mục môn thể thao (activity_type_id, mã, tên). Cần để tạo hoặc đổi môn của buổi tập.

## get_training_records
Các kỷ lục cá nhân hiện tại (pace nhanh nhất, quãng đường dài nhất, mức tạ cao nhất...).

## list_sleep
Liệt kê các đêm ngủ trong một khoảng ngày thức dậy (tối đa 62 ngày): sleep_id, giờ đi ngủ, giờ dậy, tổng giờ ngủ, hiệu suất, điểm.

## get_sleep_debt
Nợ ngủ tích luỹ 14 ngày so với mục tiêu ngủ mỗi đêm, kèm từng ngày.

## list_body_metrics
Lịch sử cân nặng, chiều cao, % mỡ, khối cơ, vòng eo trong một khoảng ngày.

## create_meal
ĐỀ XUẤT ghi một bữa ăn mới (chờ người dùng xác nhận). Truyền mô tả món và khẩu phần bằng lời; hệ thống tự tách thành phần và tra dinh dưỡng giống tính năng "Nhập tay" — không tự điền calo.

## update_meal
ĐỀ XUẤT sửa thông tin chung của bữa ăn: loại bữa, thời điểm ăn, tên món, ghi chú (chờ xác nhận). Không đổi thành phần.

## update_meal_item
ĐỀ XUẤT đổi khối lượng (gram) một thành phần của bữa ăn; calo và macro được co giãn theo tỉ lệ (chờ xác nhận).

## delete_meal_item
ĐỀ XUẤT xoá một thành phần khỏi bữa ăn (chờ xác nhận).

## add_meal_items
ĐỀ XUẤT thêm món vào một bữa đã có (chờ xác nhận). Cả bữa sẽ được phân tích lại từ các thành phần hiện tại cộng với mô tả món mới.

## delete_meal
ĐỀ XUẤT xoá cả một bữa ăn (chờ xác nhận).

## log_water
ĐỀ XUẤT cộng thêm lượng nước uống (ml) vào một ngày; số âm để bớt khi ghi nhầm (chờ xác nhận).

## create_workout
ĐỀ XUẤT ghi một buổi tập nhập tay (chờ xác nhận). Cần activity_type_id (lấy từ list_activity_types), thời điểm bắt đầu và thời lượng. Không truyền calo thì hệ thống tự ước tính theo MET và cân nặng.

## update_workout
ĐỀ XUẤT sửa một buổi tập: môn, thời lượng, quãng đường, calo, tiêu đề, ghi chú (chờ xác nhận).

## delete_workout
ĐỀ XUẤT xoá một buổi tập (chờ xác nhận).

## log_sleep
ĐỀ XUẤT ghi một đêm ngủ nhập tay: giờ đi ngủ, giờ thức dậy, số phút nằm chờ ngủ (chờ xác nhận). Mỗi ngày thức dậy chỉ có một đêm — ghi lại sẽ thay đêm cũ.

## update_sleep
ĐỀ XUẤT sửa giờ đi ngủ / giờ thức dậy của một đêm đã ghi (chờ xác nhận).

## log_body_metrics
ĐỀ XUẤT ghi chỉ số cơ thể: cân nặng, chiều cao, % mỡ, khối cơ, vòng eo — cần ít nhất một chỉ số (chờ xác nhận).
