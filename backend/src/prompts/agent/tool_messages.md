<!--
Nội dung trả về cho model trong kết quả tool (role=tool) — services/agent/agent.ts đọc bằng promptSections.
Biến theo từng mục:
- pending_confirmation: không có
- duplicate_proposal:  không có
- too_many_proposals:  {{max}}
- tool_budget:         không có
- invalid_args:        {{issues}}
- unknown_tool:        {{name}}
- tool_failed:         {{error}}
- result_truncated:    {{omitted}}
- result_too_long:     không có
-->
## pending_confirmation
CHƯA thực hiện. Đây là đề xuất; người dùng phải bấm "Xác nhận" trên thẻ hiện dưới câu trả lời của bạn. Hãy nói ngắn gọn bạn đề xuất gì và nhắc họ xác nhận. Không nói là đã làm xong.

## duplicate_proposal
Đề xuất giống hệt đã được tạo ở trên trong lượt này — không tạo lại.

## too_many_proposals
Đã đạt tối đa {{max}} đề xuất trong một lượt. Dừng tạo thêm, trả lời người dùng và để họ xác nhận các đề xuất hiện có trước.

## tool_budget
Đã hết lượt gọi tool cho câu hỏi này. Trả lời người dùng bằng dữ liệu đã có.

## invalid_args
Tham số không hợp lệ: {{issues}}. Sửa tham số rồi gọi lại, hoặc hỏi người dùng phần còn thiếu.

## unknown_tool
Không có tool tên "{{name}}". Chỉ dùng các tool được cung cấp.

## tool_failed
Lỗi: {{error}}

## result_truncated
Kết quả quá dài nên đã lược bớt {{omitted}} dòng ở cuối danh sách. Dữ liệu còn lại vẫn đúng và đầy đủ cho phần đầu khoảng thời gian; cần phần bị lược thì gọi lại với khoảng ngày ngắn hơn.

## result_too_long
Kết quả quá dài để gửi lại. Gọi lại với khoảng ngày ngắn hơn hoặc tool chi tiết hơn cho từng bản ghi.
