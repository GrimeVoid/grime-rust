from main import main


def test_main(capsys) -> None:
    main()
    captured = capsys.readouterr()
    assert "{{PROJECT_NAME}}" in captured.out
