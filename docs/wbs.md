# Home NAS

## 1. Instalace OS

### 1.1 Instalace systému

* 1.1.1 Stáhnout ISO
* 1.1.2 Nabootovat instalátor

### 1.2 Základní konfigurace systému

* 1.2.1 Nastavit root uživatele
* 1.2.2 Nastavit síťové rozhraní (NIC)
* 1.2.3 Vypnout enterprise repozitáře a nastavit běžné uživatelské

## 2. Nastavení GitHub ENV Secrets/Vars

### 2.1 Návrh proměnných

* 2.1.1 Definovat formát názvů proměnných, aby se v desítkách proměnných dalo orientovat
* 2.1.2 Rozhodnout, co všechno budou proměnné umožňovat a které jsou naopak zbytečné

### 2.2 Dokumentace proměnných

* 2.2.1 Zdokumentovat účel každé proměnné
* 2.2.2 Zdokumentovat, kde se daná hodnota nachází
* 2.2.3 Zdokumentovat, co všechno proměnná ovlivňuje

## 3. Naprogramovat CI/CD stack

### 3.1 První nasazení

* 3.1.1 Rozhodnout o přístupu k prvnímu nasazení (bash only, bash + GH Actions, GH Actions only)
* 3.1.2 Zmapovat, co všechno bude skript nastavovat a co by naopak duplikovalo CD
* 3.1.3 Naprogramovat první nasazení

### 3.2 CI pipeline

* 3.2.1 Definovat pravidla, kdy se má CI spouštět
* 3.2.2 Nastavit linting pomocných bash skriptů
* 3.2.3 Nastavit linting Terraform konfigurací
* 3.2.4 Vygenerovat Terraform plan a uložit ho pro deployment
* 3.2.5 Nastavit linting Ansible
* 3.2.6 Nastavit linting Dockeru

### 3.3 CD pipeline

* 3.3.1 Nastavit základní zabezpečení a pravidla tak, aby šlo CD spustit jen z main branche apod.
* 3.3.2 Stáhnout Terraform plan z CI pipeline a vyhodnotit změny oproti předchozí verzi
* 3.3.3 Detekovat změny v Ansible a Terraform vrstvě a podle nich aktualizovat Ansible
* 3.3.4 Detekovat změny v Docker, Ansible a Terraform vrstvě a podle nich nasadit změny Dockeru

### 3.4 Terraform vrstva

* 3.4.1 Navrhnout rozvržení VM a LXC kontejnerů (managed/unmanaged)
* 3.4.2 Naprogramovat strukturu LXC a VM
* 3.4.3 Definovat všechny proměnné a napojit je na GitHub

### 3.5 Ansible vrstva

* 3.5.1 Zjistit, co je v jednotlivých VM/LXC potřeba nakonfigurovat nebo nainstalovat
* 3.5.2 Definovat všechny potřebné balíčky a konfigurace
* 3.5.3 Nastavit všechny proměnné a provázat je s GitHubem

### 3.6 Docker vrstva

* 3.6.1 Rozhodnout, co všechno bude v Dockeru běžet a kde
* 3.6.2 Definovat Docker Compose soubory
* 3.6.3 Navrhnout strukturu dat jednotlivých kontejnerů na disku
* 3.6.4 Napojit volumes na správný storage (RAID pool nebo OS drive)

## 4. Rozběhnutí storage poolu

### 4.1 Nastavení storage poolu

* 4.1.1 Nakonfigurovat potřebné proměnné v GitHubu
* 4.1.2 Vytvořit RAID5 pool
* 4.1.3 Naformátovat pole
* 4.1.4 Nastavit přístup ostatním VM/LXC

## 5. Backup a monitoring

### 5.1 Zálohování

* 5.1.1 Navrhnout rozvržení záloh konfigurace
* 5.1.2 Rozhodnout o způsobu zálohování dat z poolu

### 5.2 Monitoring

* 5.2.1 Přidat nástroje pro monitoring
* 5.2.2 Nastavit alerting

## 6. Dokumentace a návody

### 6.1 Dokumentace kódu

* 6.1.1 Definovat standardy pro jednotlivé části kódu
* 6.1.2 Implementovat standardy do linterů
* 6.1.3 Aplikovat standardy v celém kódu

### 6.2 Dokumentace projektu jako celku

* 6.2.1 Navrhnout strukturu markdownů a sepsat rozcestník do root README
* 6.2.2 Sepsat jednotlivé markdowny

### 6.3 Návody pro širokou veřejnost

* 6.3.1 Vytvořit návod na instalaci OS
* 6.3.2 Vytvořit návod na nastavení repozitáře a proměnných společně se základním nastavením systému
* 6.3.3 Vytvořit návod na první nasazení
* 6.3.4 Vytvořit návod na provádění změn
* 6.3.5 Stručně popsat, co je kde možné upravit a co je potřeba změnit, např. při přidání dalšího VM s Dockerem a images
