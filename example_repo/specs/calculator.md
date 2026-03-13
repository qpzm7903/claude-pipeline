# Calculator 规格说明

## 功能需求

实现一个 `Calculator` 类，支持基本四则运算。

## 接口定义

```python
class Calculator:
    def add(self, a: float, b: float) -> float: ...
    def subtract(self, a: float, b: float) -> float: ...
    def multiply(self, a: float, b: float) -> float: ...
    def divide(self, a: float, b: float) -> float: ...
```

## 约束条件

- `divide` 在除数为 0 时应抛出 `ZeroDivisionError`
- 所有方法接受 int 和 float 类型参数
- 结果以 float 返回

## 测试用例示例

- `add(2, 3)` → `5.0`
- `subtract(10, 4)` → `6.0`
- `multiply(3, 4)` → `12.0`
- `divide(10, 2)` → `5.0`
- `divide(5, 0)` → 抛出 `ZeroDivisionError`
