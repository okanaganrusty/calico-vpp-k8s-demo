http-server:
	python3 -m http.server 8080

ansible:
	ansible-playbook -i inventory playbook.yml
