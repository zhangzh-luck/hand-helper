"""Generate an Argon2id hash for ADMIN_PASSWORD_HASH without echoing input."""
from getpass import getpass

from argon2 import PasswordHasher, Type


def main() -> None:
    password = getpass("请输入新的管理员密码：")
    confirmation = getpass("再次输入以确认：")
    if not password:
        raise SystemExit("密码不能为空。")
    if password != confirmation:
        raise SystemExit("两次输入的密码不一致。")
    print(PasswordHasher(type=Type.ID).hash(password))


if __name__ == "__main__":
    main()
