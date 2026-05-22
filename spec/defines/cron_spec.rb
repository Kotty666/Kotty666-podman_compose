# frozen_string_literal: true

require 'spec_helper'

describe 'podman_compose::cron' do
  let(:title) { 'backup' }
  let(:pre_condition) { 'include podman_compose' }

  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      context 'rootful, basic schedule' do
        let(:params) do
          {
            'rootless'    => false,
            'on_calendar' => 'daily',
            'compose'     => {
              'services' => {
                'job' => { 'image' => 'busybox:latest' },
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_file('/etc/systemd/system/podman-compose-cron-backup.service') }
        it { is_expected.to contain_file('/etc/systemd/system/podman-compose-cron-backup.timer') }
      end

      context 'rootless requires user' do
        let(:params) do
          {
            'rootless'    => true,
            'on_calendar' => 'daily',
            'compose'     => {
              'services' => {
                'job' => { 'image' => 'busybox:latest' },
              },
            },
          }
        end

        it { is_expected.to compile.and_raise_error(%r{'user' is required when rootless}) }
      end

      context 'run_service mode' do
        let(:params) do
          {
            'rootless'    => false,
            'on_calendar' => '*-*-* 02:00:00',
            'run_service' => 'restic',
            'compose'     => {
              'services' => {
                'restic' => { 'image' => 'restic/restic:0.17' },
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }
      end

      context 'ensure => absent' do
        let(:params) do
          {
            'ensure'      => 'absent',
            'rootless'    => false,
            'on_calendar' => 'daily',
            'compose'     => {
              'services' => {
                'job' => { 'image' => 'busybox:latest' },
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }
      end
    end
  end
end
