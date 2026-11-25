.PHONY: loop ping prepare bootstrap hosts osds verify all pools destroy
ping:      ; ansible all -m ping
prepare:   ; ansible-playbook playbooks/01-prepare.yml
bootstrap: ; ansible-playbook playbooks/02-bootstrap.yml
hosts:     ; ansible-playbook playbooks/03-add-hosts.yml
loop:      ; ansible-playbook playbooks/03a-loop-osd.yml
osds:      ; ansible-playbook playbooks/04-osds.yml
verify:    ; ansible-playbook playbooks/05-verify.yml
pools:     ; ansible-playbook playbooks/06-pools.yml
all:       ; ansible-playbook playbooks/site.yml
destroy:   ; ansible-playbook playbooks/99-destroy.yml
