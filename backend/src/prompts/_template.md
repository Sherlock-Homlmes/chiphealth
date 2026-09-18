<!--
TEMPLATE MẪU cho một prompt. Copy file này, đổi tên, rồi đăng ký trong src/prompts/index.ts.

Quy ước:
- Mỗi prompt là một file .md trong src/prompts/<nhóm>/<tên>.md, được bundle như text
  (wrangler [[rules]] type = "Text"), nên không có đọc file lúc chạy.
- Khối comment HTML như khối này là tài liệu cho người đọc: renderPrompt() xoá nó
  trước khi gửi cho model. Ghi ở đây: prompt dùng ở đâu, có những biến nào.
- Biến viết dạng {{ten_bien}} (chữ, số, gạch dưới). renderPrompt(PROMPTS.x, { ten_bien: ... })
  thay một lượt duy nhất — giá trị được thay vào KHÔNG bị render lại, nên dữ liệu
  người dùng có chứa "{{...}}" không thể chèn biến khác.
- Thiếu biến => renderPrompt ném lỗi ngay (không gửi prompt hỏng cho model).
- File có nhiều mục (vd agent/tools.md) dùng tiêu đề "## <khoá>" và đọc bằng promptSections().

Biến của template mẫu này:
- {{role}}      vai trò của model
- {{task}}      việc cần làm
- {{format}}    định dạng đầu ra
-->
Bạn là {{role}}.

Nhiệm vụ: {{task}}

Trả về: {{format}}
