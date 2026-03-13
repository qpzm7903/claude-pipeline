# String Utils 规格说明

## 功能需求

实现 `reverse_string` 函数。

## 接口定义

```python
def reverse_string(s: str) -> str:
    """反转输入字符串并返回。"""
```

## 约束条件

- 空字符串返回空字符串
- 支持 Unicode 字符（中文、emoji 等）
- 不修改原字符串（返回新字符串）

## 测试用例

- `reverse_string("hello")` → `"olleh"`
- `reverse_string("")` → `""`
- `reverse_string("a")` → `"a"`
- `reverse_string("你好")` → `"好你"`
