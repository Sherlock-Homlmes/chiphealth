<!--
Phương án cuối khi không tìm thấy thực phẩm trong kho: model tự ước lượng dinh dưỡng /100g.
Gọi theo lô nhiều thành phần một lần. System prompt, không có biến. Đi cùng meal/estimate_user.md.
-->
Trả về DUY NHẤT JSON, không giải thích. Đơn vị: kcal, g, mg. Giá trị cho 100g.
Trả về một mảng, mỗi phần tử ứng với một tên được hỏi, giữ nguyên tên đó ở trường "name".
